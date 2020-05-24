module BSDiff

export bsdiff, bspatch, bsindex

using SuffixArrays
using TranscodingStreams, CodecBzip2
using TranscodingStreams: Codec
using BufferedStreams

# abstract Patch format type
# specific formats defined below
abstract type Patch end

# control over compression details

function lowmem()
    haskey(ENV, "JULIA_BSDIFF_LOWMEM") || return false
    val = lowercase(ENV["JULIA_BSDIFF_LOWMEM"])
    val in ("1", "true", "t", "yes", "y") && return true
    val in ("0", "false", "f", "no", "n") && return false
    error("invalid value for JULIA_BSDIFF_LOWMEM: $(repr(val))")
end

compressor() = Bzip2Compressor(blocksize100k = lowmem() ? 1 : 9)
decompressor() = Bzip2Decompressor(small = lowmem())

# specific format implementations

include("classic.jl")
include("endsley.jl")

# format names, patch types, auto detection

const DEFAULT_FORMAT = :classic
const FORMATS = Dict{Symbol,Type{<:Patch}}()
const MAGICS = Vector{Pair{Symbol,String}}()

function register_format!(format::Symbol, type::Type{<:Patch})
    magic = format_magic(type)
    FORMATS[format] = type
    push!(MAGICS, format => magic)
    sort!(MAGICS, by = ncodeunits∘last)
    return
end

register_format!(:classic, ClassicPatch)
register_format!(:endsley, EndsleyPatch)

function patch_type(format::Symbol)
    type = get(FORMATS, format, nothing)
    type !== nothing && return type
    throw(ArgumentError("unknown patch format: $format"))
end

function detect_format(patch_io::IO)
    data = UInt8[]
    for (format, magic) in MAGICS
        n = ncodeunits(magic)
        m = n - length(data)
        m > 0 && append!(data, read(patch_io, m))
        view(data, 1:n) == codeunits(magic) && return format
    end
    return :unknown
end
detect_format(path::AbstractString) = open(detect_format, path)

const INDEX_HEADER = "SUFFIX ARRAY\0"

## some API utilities for arguments ##

open_read(f::Function, file::AbstractString) = open(f, file)
open_read(f::Function, file::IO) = f(file)

function open_write(f::Function, file::AbstractString)
    try open(f, file, write=true)
    catch
        rm(file, force=true)
        rethrow()
    end
    return file
end
function open_write(f::Function, file::Nothing)
    file, io = mktemp()
    try f(io)
    catch
        close(io)
        rm(file, force=true)
        rethrow()
    end
    close(io)
    return file
end
function open_write(f::Function, file::IO)
    f(file)
    return file
end

## high-level API (similar to the C tool) ##

"""
    bsdiff(old, new, [ patch ]; format = [ :classic | :endsley ]) -> patch

Compute a binary patch that will transform the content of `old` into the content
of `new`. All arguments can be strings or IO handles. If no `patch` argument is
provided, the patch data is written to a temporary file whose path is returned.

The `old` argument can also be a 2-tuple of strings and/or IO handles, in which
case the first is used as the old data and the second is used as a precomputed
index of the old data, as computed by [`bsindex`](@ref). Since indexing the old
data is the slowest part of generating a diff, pre-computing this and reusing it
can significantly speed up generting diffs from the same old file to multiple
different new files.

The `format` keyword argument allows selecting a patch format to generate. The
value must be one of the symbols `:classic` or `:endsley` indicating a bsdiff
patch format. The classic patch format is generated by default, but the Endsley
format can be selected by with `bsdiff(old, new, patch, format = :endsley)`.
"""
function bsdiff(
    old::Union{AbstractString, IO, NTuple{2, Union{AbstractString, IO}}},
    new::Union{AbstractString, IO},
    patch::Union{AbstractString, IO, Nothing} = nothing;
    format::Symbol = DEFAULT_FORMAT,
)
    type = patch_type(format)
    old_data, index = data_and_index(old)
    new_data = open_read(read, new)
    open_write(patch) do patch_io
        write(patch_io, format_magic(type))
        patch_obj = write_start(type, patch_io, old_data, new_data)
        generate_patch(patch_obj, old_data, new_data, index)
        write_finish(patch_obj)
    end
end

"""
    bspatch(old, [ new, ] patch; format = [ :classic | :endsley ]) -> new

Apply a binary patch given by the `patch` argument to the content of `old` to
producing the content of `new`. All arguments can be strings or IO handles. If
no `new` argument is passed, the new data is written to a temporary file whose
path is returned.

Note that the optional argument is the middle argument, which is a bit unusual
but makes the argument order when passing all three paths consistent with the
`bspatch` command and with the `bsdiff` function.

The `format` keyword argument allows restricting the patch format that `bspatch`
will accept. By default `bspatch` auto-detects the patch format. If a format is
given then it will raise an error unless the patch file has the expected format.
"""
function bspatch(
    old::Union{AbstractString, IO},
    new::Union{AbstractString, IO, Nothing},
    patch::Union{AbstractString, IO};
    format::Symbol = :auto,
)
    format == :auto || format in keys(FORMATS) ||
        error("unknown patch format: $format")
    old_data = open_read(read, old)
    open_read(patch) do patch_io
        detected = detect_format(patch_io)
        detected == :unknown && error("unrecognized/corrupt patch file")
        format == :auto || format == detected ||
            error("patch has $detected format, expected $format format")
        type = patch_type(detected)
        patch_obj = read_start(type, patch_io)
        open_write(new) do new_io
            new_io = BufferedOutputStream(new_io)
            apply_patch(patch_obj, old_data, new_io)
            flush(new_io)
        end
    end
end

function bspatch(
    old::Union{AbstractString, IO},
    patch::Union{AbstractString, IO};
    format::Symbol = :auto,
)
    bspatch(old, nothing, patch; format = format)
end

"""
    bsindex(old, [ index ]) -> index

Save index data (a sorted suffix array) for the content of `old` into `index`.
All arguments can be strings or IO handles. If no `index` argument is given, the
index data is saved to a temporary file whose path is returned. The index can be
passed to `bsdiff` to speed up the diff computation by passing `(old, index)` as
the first argument instead of just `old`.
"""
function bsindex(
    old::Union{AbstractString, IO},
    index::Union{AbstractString, IO, Nothing} = nothing,
)
    old_data = open_read(read, old)
    open_write(index) do index_io
        write(index_io, INDEX_HEADER)
        index_data = generate_index(old_data)
        write(index_io, UInt8(sizeof(eltype(index_data))))
        write(index_io, index_data)
    end
end

## loading data and index ##

const IndexType{T<:Integer} = Vector{T}

function data_and_index(data_path::Union{AbstractString, IO})
    data = open_read(read, data_path)
    data, generate_index(data)
end

function data_and_index(
    (data_path, index_path)::NTuple{2, Union{AbstractString, IO}},
)
    data = open_read(read, data_path)
    index = open_read(index_path) do index_io
        hdr = String(read(index_io, ncodeunits(INDEX_HEADER)))
        hdr == INDEX_HEADER || error("corrupt bsdiff index file")
        unit = Int(read(index_io, UInt8))
        T = unit == 1 ? UInt8 :
            unit == 2 ? UInt16 :
            unit == 4 ? UInt32 :
            unit == 8 ? UInt64 :
            error("invalid unit size for bsdiff index file: $unit")
        read!(index_io, Vector{T}(undef, length(data)))
    end
    return data, index
end

## generic patch generation and application logic ##

generate_index(data::AbstractVector{<:UInt8}) = suffixsort(data, 0)

# transform used to serialize integers to avoid lots of
# high bytes being emitted for small negative values
int_io(x::Signed) = ifelse(x == abs(x), x, typemin(x) - x)
write_int(io::IO, x::Signed) = write(io, int_io(Int64(x)))
read_int(io::IO) = Int(int_io(read(io, Int64)))

"""
Return lexicographic order and length of common prefix.
"""
function strcmplen(p::Ptr{UInt8}, m::Int, q::Ptr{UInt8}, n::Int)
    i = 0
    while i < min(m, n)
        a = unsafe_load(p + i)
        b = unsafe_load(q + i)
        a ≠ b && return (a - b) % Int8, i
        i += 1
    end
    return (m - n) % Int8, i
end

"""
Search for the longest prefix of new[t:end] in old.
Uses the suffix array of old to search efficiently.
"""
function prefix_search(
    index::IndexType, # suffix array
    old::AbstractVector{UInt8}, # old data to search in
    new::AbstractVector{UInt8}, # new data to search for
    t::Int, # search for longest match of new[t:end]
)
    old_n = length(old)
    new_n = length(new) - t + 1
    old_p = pointer(old)
    new_p = pointer(new, t)
    # invariant: longest match is in index[lo:hi]
    lo, hi = 1, old_n
    c = lo_c = hi_c = 0
    while hi - lo ≥ 2
        m = (lo + hi) >>> 1
        s = index[m]
        x, l = strcmplen(new_p+c, new_n+c, old_p+s+c, old_n-s-c)
        if 0 < x
            lo, lo_c = m, c+l
        else
            hi, hi_c = m, c+l
        end
        c = min(lo_c, hi_c)
    end
    lo_c > hi_c ? (index[lo]+1, lo_c) : (index[hi]+1, hi_c)
end

"""
Computes and emits the diff of the byte vectors `new` versus `old`.
The `index` array is a zero-based suffix array of `old`.
"""
function generate_patch(
    patch::Patch,
    old::AbstractVector{UInt8},
    new::AbstractVector{UInt8},
    index::IndexType = generate_index(old),
)
    oldsize, newsize = length(old), length(new)
    scan = len = pos = lastscan = lastpos = lastoffset = 0

    while scan < newsize
        oldscore = 0
        scsc = scan += len
        while scan < newsize
            pos, len = prefix_search(index, old, new, scan+1)
            pos -= 1 # zero-based
            while scsc < scan + len
                oldscore += scsc + lastoffset < oldsize &&
                    old[scsc + lastoffset + 1] == new[scsc + 1]
                scsc += 1
            end
            if len == oldscore && len ≠ 0 || len > oldscore + 8
                break
            end
            oldscore -= scan + lastoffset < oldsize &&
                old[scan + lastoffset + 1] == new[scan + 1]
            scan += 1
        end
        if len ≠ oldscore || scan == newsize
            i = s = Sf = lenf = 0
            while lastscan + i < scan && lastpos + i < oldsize
                s += old[lastpos + i + 1] == new[lastscan + i + 1]
                i += 1
                if 2s - i > 2Sf - lenf
                    Sf = s
                    lenf = i
                end
            end
            lenb = 0
            if scan < newsize
                s = Sb = 0
                i = 1
                while scan ≥ lastscan + i && pos ≥ i
                    s += old[pos - i + 1] == new[scan - i + 1]
                    if 2s - i > 2Sb - lenb
                        Sb = s
                        lenb = i
                    end
                    i += 1
                end
            end
            if lastscan + lenf > scan - lenb
                overlap = (lastscan + lenf) - (scan - lenb)
                i = s = Ss = lens = 0
                while i < overlap
                    s += new[lastscan + lenf - overlap + i + 1] ==
                         old[lastpos + lenf - overlap + i + 1]
                    s -= new[scan - lenb + i + 1] ==
                         old[pos - lenb + i + 1]
                    if s > Ss
                        Ss = s
                        lens = i + 1;
                    end
                    i += 1
                end
                lenf += lens - overlap
                lenb -= lens
            end

            diff_size = lenf
            copy_size = (scan - lenb) - (lastscan + lenf)
            skip_size = (pos - lenb) - (lastpos + lenf)

            # skip if both blocks are empty
            diff_size == copy_size == 0 && continue

            encode_control(patch, diff_size, copy_size, skip_size)
            encode_diff(patch, diff_size, new, lastscan, old, lastpos)
            encode_data(patch, copy_size, new, lastscan + diff_size)

            lastscan = scan - lenb
            lastpos = pos - lenb
            lastoffset = pos - scan
        end
    end
end

"""
Apply a patch stream to the `old` data buffer, emitting a `new` data stream.
"""
function apply_patch(
    patch::Patch,
    old::AbstractVector{UInt8},
    new::IO,
    new_size::Int = hasfield(typeof(patch), :new_size) ? patch.new_size : typemax(Int),
)
    old_pos = new_pos = 0
    old_size = length(old)
    while true
        ctrl = decode_control(patch)
        ctrl == nothing && break
        diff_size, copy_size, skip_size = ctrl

        # sanity checks
        0 ≤ diff_size && 0 ≤ copy_size &&                # block sizes are non-negative
        new_pos + diff_size + copy_size ≤ new_size &&    # don't write > new_size bytes
        0 ≤ old_pos && old_pos + diff_size ≤ old_size || # bounds check for old data
            error("corrupt bsdiff patch")

        decode_diff(patch, diff_size, new, old, old_pos)
        decode_data(patch, copy_size, new)

        new_pos += diff_size + copy_size
        old_pos += diff_size + skip_size
    end
    return new_pos
end

end # module
