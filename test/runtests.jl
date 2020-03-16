using Test
using BSDiff
using Pkg.Artifacts

import bsdiff_classic_jll
import bsdiff_endsley_jll

const test_data = artifact"test_data"
const FORMATS = sort!(collect(keys(BSDiff.FORMATS)))

@testset "BSDiff" begin
    @testset "API coverage" begin
        # create new, old and reference patch files
        dir = mktempdir()
        old_file = joinpath(dir, "old")
        new_file = joinpath(dir, "new")
        suffix_file = joinpath(dir, "suffixes")
        write(old_file, "Goodbye, world.")
        write(new_file, "Hello, world!")
        for format in [nothing; FORMATS]
            fmt = format == nothing ? [] : [:format => format]
            # check API passing only two paths
            @testset "2-arg API" begin
                patch_file = bsdiff(old_file, new_file; fmt...)
                new_file′ = bspatch(old_file, patch_file; fmt...)
                @test read(new_file′, String) == "Hello, world!"
                new_file′ = bspatch(old_file, patch_file) # format auto-detected
                @test read(new_file′, String) == "Hello, world!"
            end
            # check API passing all three paths
            @testset "3-arg API" begin
                patch_file = joinpath(dir, "patch")
                new_file′ = joinpath(dir, "new′")
                bsdiff(old_file, new_file, patch_file; fmt...)
                bspatch(old_file, new_file′, patch_file; fmt...)
                @test read(new_file′, String) == "Hello, world!"
                bspatch(old_file, new_file′, patch_file) # format auto-detected
                @test read(new_file′, String) == "Hello, world!"
            end
            @testset "bsindex API" begin
                bsindex(old_file, suffix_file)
                patch_file = bsdiff((old_file, suffix_file), new_file; fmt...)
                new_file′ = bspatch(old_file, patch_file; fmt...)
                @test read(new_file′, String) == "Hello, world!"
                # test that tempfile API makes the same file
                suffix_file′ = bsindex(old_file)
                @test read(suffix_file) == read(suffix_file′)
            end
        end
        rm(dir, recursive=true, force=true)
    end
    @testset "registry data" begin
        registry_data = joinpath(test_data, "registry")
        old = joinpath(registry_data, "before.tar")
        new = joinpath(registry_data, "after.tar")
        ref = joinpath(registry_data, "reference.diff")
        old_data = read(old)
        new_data = read(new)
        @testset "zrl data" begin
            old_zrl = "$old.zrl"
            new_zrl = "$new.zrl"
            write(old_zrl, BSDiff.read_zrle(old))
            write(new_zrl, BSDiff.read_zrle(new))
            index = bsindex(old_zrl)
            for format in FORMATS
                @show format
                patch = @time bsdiff((old_zrl, index), new_zrl, format = format)
                patch = @time bsdiff((old_zrl, index), new_zrl, format = format)
                patch = @time bsdiff((old_zrl, index), new_zrl, format = format)
                new_zrl′ = bspatch(old_zrl, patch)
                @test read(new_zrl) == read(new_zrl′)
            end
            # eliminate I/O overhead
            old_zrl_data = read(old_zrl)
            new_zrl_data = read(new_zrl)
            index_data = BSDiff.generate_index(old_zrl_data)
            for PatchType in [BSDiff.EndsleyPatch, BSDiff.SparsePatch]
                println("$PatchType generation to devnull:")
                patch = PatchType(devnull, length(new_zrl_data))
                @time BSDiff.generate_patch(patch, old_zrl_data, new_zrl_data, index_data)
                @time BSDiff.generate_patch(patch, old_zrl_data, new_zrl_data, index_data)
                @time BSDiff.generate_patch(patch, old_zrl_data, new_zrl_data, index_data)
                println("$PatchType generation to IOBuffer:")
                diff = sprint() do io
                    patch = PatchType(io, length(new_zrl_data))
                    @time BSDiff.generate_patch(patch, old_zrl_data, new_zrl_data, index_data)
                    @time BSDiff.generate_patch(patch, old_zrl_data, new_zrl_data, index_data)
                    @time BSDiff.generate_patch(patch, old_zrl_data, new_zrl_data, index_data)
                end |> codeunits
            end
        end
        @testset "hi-level API" for format in FORMATS
            @show format
            index = bsindex(old)
            patch = @time bsdiff((old, index), new, format = format)
            patch = @time bsdiff((old, index), new, format = format)
            patch = @time bsdiff((old, index), new, format = format)
            new′ = bspatch(old, patch)
            @show filesize(patch)
        end
        @testset "low-level API" begin
            # test that diff is identical to reference diff
            diff = sprint() do io
                patch = BSDiff.EndsleyPatch(io, length(new_data))
                BSDiff.generate_patch(patch, old_data, new_data)
            end |> codeunits
            @test read(ref) == diff
            # test that applying reference patch to old produces new
            new_data′ = open(ref) do io
                sprint() do new_io
                    patch = BSDiff.EndsleyPatch(io, length(new_data))
                    BSDiff.apply_patch(patch, old_data, new_io)
                end |> codeunits
            end
            @test new_data == new_data′
        end
        if !Sys.iswindows() # bsdiff JLLs don't compile on Windows
            for (format, jll) in [
                    (:classic, bsdiff_classic_jll),
                    (:endsley, bsdiff_endsley_jll),
                ]
                @testset "compatibility" begin
                    # test that bspatch command accepts patches we generate
                    patch = bsdiff(old, new, format = format)
                    new′ = tempname()
                    jll.bspatch() do bspatch
                        run(`$bspatch $old $new′ $patch`)
                    end
                    @test new_data == read(new′)
                    rm(new′)
                    # test that we accept patches generated by bsdiff command
                    patch = tempname()
                    jll.bsdiff() do bsdiff
                        run(`$bsdiff $old $new $patch`)
                    end
                    new′ = bspatch(old, patch, format = format)
                    @test new_data == read(new′)
                    new′ = bspatch(old, patch) # format auto-detected
                    @test new_data == read(new′)
                end
            end
        end
    end
end
