## Basic tests for simple utilities within BB
using BinaryBuilder, Test, Pkg
using BinaryBuilder: preferred_runner, resolve_jlls, CompilerShard, preferred_libgfortran_version, preferred_cxxstring_abi, gcc_version, available_gcc_builds, getversion, generate_compiler_wrappers!

@testset "File Collection" begin
    temp_prefix() do prefix
        # Create a file and a link, ensure that only the one file is returned by collect_files()
        f = joinpath(prefix, "foo")
        f_link = joinpath(prefix, "foo_link")
        touch(f)
        symlink(f, f_link)
        d = joinpath(prefix, "bar")
        d_link = joinpath(prefix, "bar_link")
        mkpath(d)
        symlink(d, d_link)

        files = collect_files(prefix)
        @test length(files) == 2
        @test realpath(f) in files
        @test realpath(f_link) in files
        @test !(realpath(d) in files)
        @test !(realpath(d_link) in files)

        collapsed_files = collapse_symlinks(files)
        @test length(collapsed_files) == 1
        @test realpath(f) in collapsed_files

        files = collect_files(prefix, exclude_dirs = false)
        @test length(files) == 4
        @test realpath(f) in files
        @test realpath(f_link) in files
        @test realpath(d) in files
        @test realpath(d_link) in files

        files = collect_files(prefix, islink)
        @test length(files) == 1
        @test !(realpath(f) in files)
        @test f_link in files
        @test !(realpath(d) in files)
        @test !(d_link in files)

        files = collect_files(prefix, islink, exclude_dirs = false)
        @test length(files) == 2
        @test !(realpath(f) in files)
        @test f_link in files
        @test !(realpath(d) in files)
        @test d_link in files
    end
end

@testset "Supported Platforms" begin
    all = supported_platforms()
    opt_out_specific = supported_platforms(exclude=[Linux(:x86_64, libc=:glibc)])
    islin(x) = typeof(x) == Linux
    opt_out_fx = supported_platforms(exclude=islin)

    @test length(all) == length(opt_out_specific)+1
    @test any(opt_out_specific .== [Linux(:i686 , libc=:glibc)])
    @test !any(opt_out_fx .== [Linux(:i686 , libc=:glibc)])
end

@testset "Target properties" begin
    for p in [Linux(:i686), Windows(:i686), Linux(:armv7l)]
        @test BinaryBuilder.nbits(p) == 32
    end

    for p in [Linux(:x86_64), Windows(:x86_64), Linux(:aarch64),
              Linux(:powerpc64le), MacOS()]
        @test BinaryBuilder.nbits(p) == 64
    end

    for p in [Linux(:x86_64), MacOS(), Windows(:i686)]
        @test BinaryBuilder.proc_family(p) == :intel
    end
    for p in [Linux(:aarch64; libc=:musl), Linux(:armv7l)]
        @test BinaryBuilder.proc_family(p) == :arm
    end
    @test BinaryBuilder.proc_family(Linux(:powerpc64le)) == :power

    for p in [Linux(:aarch64), FreeBSD(:x86_64)]
        @test BinaryBuilder.dlext(p) == "so"
    end
    @test BinaryBuilder.dlext(MacOS()) == "dylib"
    @test BinaryBuilder.dlext(Windows(:i686)) == "dll"

    for p in [Linux(:x86_64), FreeBSD(:x86_64), Linux(:powerpc64le), MacOS()]
        @test BinaryBuilder.exeext(p) == ""
    end
    @test BinaryBuilder.exeext(Windows(:x86_64)) == ".exe"
    @test BinaryBuilder.exeext(Windows(:i686)) == ".exe"
end

# Are we using docker? If so, test that the docker runner works...
@testset "Runner utilities" begin
    # Test that is_ecryptfs works for something we're certain isn't encrypted
    if isdir("/proc")
        isecfs = (false, "/proc/")
        @test BinaryBuilder.is_ecryptfs("/proc"; verbose=true) == isecfs
        @test BinaryBuilder.is_ecryptfs("/proc/"; verbose=true) == isecfs
        @test BinaryBuilder.is_ecryptfs("/proc/not_a_file"; verbose=true) == isecfs
    else
        @test BinaryBuilder.is_ecryptfs("/proc"; verbose=true) == (false, "/proc")
        @test BinaryBuilder.is_ecryptfs("/proc/"; verbose=true) == (false, "/proc/")
        @test BinaryBuilder.is_ecryptfs("/proc/not_a_file"; verbose=true) == (false, "/proc/not_a_file")
    end

    if isa(preferred_runner(), BinaryBuilder.DockerRunner)
        @testset "Docker image importing" begin
            # First, delete the docker image, in case it already existed
            BinaryBuilder.delete_docker_image()

            # Next, import it and ensure that doesn't throw
            rootfs = first(BinaryBuilder.choose_shards(platform))
            mktempdir() do dir
                @test BinaryBuilder.import_docker_image(rootfs, dir; verbose=true) === nothing
            end

            # Test that deleting the docker image suceeds, now that we know
            # it exists
            @test BinaryBuilder.delete_docker_image()
        end
    end

    @testset "hello world" begin
        mktempdir() do dir
            ur = preferred_runner()(dir; platform=Linux(:x86_64; libc=:musl))
            iobuff = IOBuffer()
            @test run(ur, `/bin/bash -c "echo test"`, iobuff)
            seek(iobuff, 0)
            # Test that we get the output we expect (e.g. the second line is `test`)
            @test split(String(read(iobuff)), "\n")[2] == "test"
        end
    end
end

@testset "environment and history saving" begin
    mktempdir() do temp_path
        @test_throws ErrorException autobuild(
            temp_path,
            "this_will_fail",
            v"1.0.0",
            # No sources to speak of
            [],
            # Simple script that just sets an environment variable
            """
            MARKER=1
            exit 1
            """,
            # Build for this platform
            [platform],
            # No products
            Product[],
            # No depenedencies
            [],
        )

        # build_path is the nonce'd build directory
        build_path = joinpath(temp_path, "build", triplet(platform))
        build_path = joinpath(build_path, first(readdir(build_path)))

        # Ensure that we get a metadir, and that our history and .env files are in there!
        metadir = joinpath(build_path, "metadir")
        @test isdir(metadir)

        hist_file = joinpath(metadir, ".bash_history")
        env_file = joinpath(metadir, ".env")
        @test isfile(hist_file)
        @test isfile(env_file)

        # Test that exit 1 is in .bash_history
        @test occursin("\nexit 1\n", read(open(hist_file), String))

        # Test that MARKER=1 is in .env:
        @test occursin("\nMARKER=1\n", read(open(env_file), String))

        # Delete the build path
        rm(build_path, recursive = true)
    end
end

@testset "Wizard Utilities" begin
    # Make sure canonicalization does what we expect
    zmq_url = "https://github.com/zeromq/zeromq3-x/releases/download/v3.2.5/zeromq-3.2.5.tar.gz"
    @test BinaryBuilder.canonicalize_source_url(zmq_url) == zmq_url
    this_url = "https://github.com/JuliaPackaging/BinaryBuilder.jl/blob/1fee900486baedfce66ddb24872133ef36b9d899/test/wizard.jl"
    this_url_ans = "https://raw.githubusercontent.com/JuliaPackaging/BinaryBuilder.jl/1fee900486baedfce66ddb24872133ef36b9d899/test/wizard.jl"
    @test BinaryBuilder.canonicalize_file_url(this_url) == this_url_ans

    # Make sure normalization does what we expect
    @test BinaryBuilder.normalize_name("foo/libfoo.tar.gz") == "libfoo"
    @test BinaryBuilder.normalize_name("foo/libfoo-2.dll") == "libfoo"
    @test BinaryBuilder.normalize_name("libfoo") == "libfoo"
end

@testset "State serialization" begin
    state = BinaryBuilder.WizardState()
    state.step = :step34
    state.platforms = [Linux(:x86_64)]
    state.source_urls = ["http://127.0.0.1:14444/a/source.tar.gz"]
    state.source_files = ["/tmp/source.tar.gz"]
    state.source_hashes = [bytes2hex(sha256("a"))]
    state.name = "libfoo"
    state.version = v"1.0.0"
    state.dependencies = Any["Zlib_jll", Pkg.Types.PackageSpec(;name="CompilerSupportLibraries_jll")]
    state.history = "exit 1"

    io = Dict()
    BinaryBuilder.serialize(io, state)
    new_state = BinaryBuilder.unserialize(io)

    for field in fieldnames(BinaryBuilder.WizardState)
        @test getfield(state, field) == getfield(new_state, field)
    end
end

# Test that updating Yggdrasil works
@testset "Yggdrasil" begin
    Core.eval(BinaryBuilder, :(yggdrasil_updated = false))
    @test_logs (:info, r"Yggdrasil") BinaryBuilder.get_yggdrasil()
end

@testset "Tree symlinking" begin
    # Make sure symlink_tree works well with symlinks
    mktempdir() do tmpdir
        # Create fake source directory
        srcdir = joinpath(tmpdir, "src")
        mkdir(srcdir)

        mkdir(joinpath(srcdir, "dir"))
        open(joinpath(srcdir, "dir", "fileA"), "w") do io
            println(io, "fileA")
        end
        open(joinpath(srcdir, "dir", "fileB"), "w") do io
            println(io, "fileB")
        end
        symlink(joinpath("dir", "fileA"), joinpath(srcdir, "sym_fileA"))
        symlink("dir", joinpath(srcdir, "sym_dir"))

        dstdir = joinpath(tmpdir, "dst")

        # Set up a symlink tree inside of dstdir
        BinaryBuilder.symlink_tree(srcdir, dstdir)

        @test isdir(dstdir)
        @test isdir(joinpath(dstdir, "dir"))
        @test islink(joinpath(dstdir, "sym_dir"))
        @test islink(joinpath(dstdir, "sym_fileA"))
        @test islink(joinpath(dstdir, "dir", "fileA"))
        @test islink(joinpath(dstdir, "dir", "fileB"))

        @test readlink(joinpath(dstdir, "sym_dir")) == "dir"
        @test readlink(joinpath(dstdir, "sym_fileA")) == joinpath("dir", "fileA")

        @test String(read(joinpath(dstdir, "dir", "fileA"))) == "fileA\n"
        @test String(read(joinpath(dstdir, "dir", "fileB"))) == "fileB\n"
        @test String(read(joinpath(dstdir, "sym_fileA"))) == "fileA\n"
        @test String(read(joinpath(dstdir, "sym_dir", "fileB"))) == "fileB\n"

        # Create some files in `dstdir`, then unsymlink and see what happens:
        open(joinpath(dstdir, "dir", "fileC"), "w") do io
            println(io, "fileC")
        end
        symlink(joinpath("dir", "fileB"), joinpath(dstdir, "sym_fileB"))
        symlink(joinpath("dir", "fileC"), joinpath(dstdir, "sym_fileC"))
        symlink("dir", joinpath(dstdir, "sym_dir2"))

        BinaryBuilder.unsymlink_tree(srcdir, dstdir)

        @test isdir(dstdir)
        @test isdir(joinpath(dstdir, "dir"))
        @test !islink(joinpath(dstdir, "sym_dir"))
        @test !islink(joinpath(dstdir, "sym_fileA"))
        @test !isfile(joinpath(dstdir, "dir", "fileA"))
        @test !isfile(joinpath(dstdir, "dir", "fileB"))
        @test isfile(joinpath(dstdir, "dir", "fileC"))
        @test islink(joinpath(dstdir, "sym_dir2"))
        @test islink(joinpath(dstdir, "sym_fileB"))
        @test islink(joinpath(dstdir, "sym_fileC"))

        @test String(read(joinpath(dstdir, "dir", "fileC"))) == "fileC\n"
        @test String(read(joinpath(dstdir, "sym_fileC"))) == "fileC\n"
        @test_throws Base.IOError realpath(joinpath(dstdir, "sym_fileB"))
    end
end

@testset "resolve_jlls" begin
    # Deps given by name::String
    dependencies = ["OpenSSL_jll",]
    truefalse, resolved_deps = resolve_jlls(dependencies)
    @test truefalse
    @test all(x->x.uuid !== nothing, resolved_deps)
    # Deps given by name::PackageSpec
    dependencies = [PackageSpec(name="OpenSSL_jll"),]
    truefalse, resolved_deps = resolve_jlls(dependencies)
    @test truefalse
    @test all(x->x.uuid !== nothing, resolved_deps)
    # Deps given by (name,uuid)::PackageSpec
    dependencies = [PackageSpec(name="OpenSSL_jll", uuid="458c3c95-2e84-50aa-8efc-19380b2a3a95"),]
    truefalse, resolved_deps = resolve_jlls(dependencies)
    @test truefalse
    @test all(x->x.uuid !== nothing, resolved_deps)
    # Deps given by combination of name::String, name::PackageSpec and (name,uuid)::PackageSpec
    dependencies = [
        "Zlib_jll",
        PackageSpec(name="Bzip2_jll"),
        PackageSpec(name="OpenSSL_jll", uuid="458c3c95-2e84-50aa-8efc-19380b2a3a95"),
    ]
    truefalse, resolved_deps = resolve_jlls(dependencies)
    @test truefalse
    @test all(x->x.uuid !== nothing, resolved_deps)
end

@testset "Compiler Shards" begin
    @test_throws ErrorException CompilerShard("GCCBootstrap", v"4", Linux(:x86_64), :invalid_archive_type)

    @testset "GCC ABI matching" begin
        # Preferred libgfortran version and C++ string ABI
        platform = FreeBSD(:x86_64)
        shard = CompilerShard("GCCBootstrap", v"4.8.5", Linux(:x86_64, libc=:musl), :squashfs, target = platform)
        @test preferred_libgfortran_version(platform, shard) == v"3"
        @test preferred_cxxstring_abi(platform, shard) == :cxx03
        shard = CompilerShard("GCCBootstrap", v"5.2.0", Linux(:x86_64, libc=:musl), :squashfs, target = platform)
        @test preferred_libgfortran_version(platform, shard) == v"3"
        @test preferred_cxxstring_abi(platform, shard) == :cxx11
        shard = CompilerShard("GCCBootstrap", v"7.1.0", Linux(:x86_64, libc=:musl), :squashfs, target = platform)
        @test preferred_libgfortran_version(platform, shard) == v"4"
        @test preferred_cxxstring_abi(platform, shard) == :cxx11
        shard = CompilerShard("GCCBootstrap", v"9.1.0", Linux(:x86_64, libc=:musl), :squashfs, target = platform)
        @test preferred_libgfortran_version(platform, shard) == v"5"
        @test preferred_cxxstring_abi(platform, shard) == :cxx11
        shard = CompilerShard("LLVMBootstrap", v"4.8.5", Linux(:x86_64, libc=:musl), :squashfs)
        @test_throws ErrorException preferred_libgfortran_version(platform, shard)
        @test_throws ErrorException preferred_cxxstring_abi(platform, shard)
        platform = Linux(:x86_64, libc=:musl)
        shard = CompilerShard("GCCBootstrap", v"4.8.5", Linux(:x86_64, libc=:musl), :squashfs, target = MacOS(:x86_64))
        @test_throws ErrorException preferred_libgfortran_version(platform, shard)
        shard = CompilerShard("GCCBootstrap", v"4.8.5", Linux(:x86_64, libc=:musl), :squashfs, target = Linux(:x86_64, libc=:glibc))
        @test_throws ErrorException preferred_cxxstring_abi(platform, shard)
        shard = CompilerShard("GCCBootstrap", v"1.2.3", Linux(:x86_64, libc=:musl), :squashfs, target = Windows(:x86_64))
        @test_throws ErrorException preferred_cxxstring_abi(platform, shard)
        @test_throws ErrorException preferred_libgfortran_version(platform, shard)

        # With no constraints, we should get them all back
        @test gcc_version(CompilerABI(), available_gcc_builds) == getversion.(available_gcc_builds)

        # libgfortran v3 and libstdcxx 22 restrict us to only v4.8, v5.2 and v6.1
        cabi = CompilerABI(;libgfortran_version=v"3", libstdcxx_version=v"3.4.22")
        @test gcc_version(cabi, available_gcc_builds) == [v"4.8.5", v"5.2.0", v"6.1.0"]

        # Adding `:cxx11` eliminates `v"4.X"`:
        cabi = CompilerABI(cabi; cxxstring_abi=:cxx11)
        @test gcc_version(cabi, available_gcc_builds) == [v"5.2.0", v"6.1.0"]

        # Just libgfortran v3 allows GCC 6 as well though
        cabi = CompilerABI(;libgfortran_version=v"3")
        @test gcc_version(cabi, available_gcc_builds) == [v"4.8.5", v"5.2.0", v"6.1.0"]

        # Test libgfortran version v4, then splitting on libstdcxx_version:
        cabi = CompilerABI(;libgfortran_version=v"4")
        @test gcc_version(cabi, available_gcc_builds) == [v"7.1.0"]
        cabi = CompilerABI(cabi; libstdcxx_version=v"3.4.23")
        @test gcc_version(cabi, available_gcc_builds) == [v"7.1.0"]
    end

    @testset "Compiler wrappers" begin
        platform = Linux(:x86_64, libc=:musl)
        mktempdir() do bin_path
            generate_compiler_wrappers!(platform; bin_path = bin_path)
            # Make sure the C++ string ABI is not set
            @test !occursin("-D_GLIBCXX_USE_CXX11_ABI", read(joinpath(bin_path, "gcc"), String))
            # Make sure gfortran doesn't uses ccache when BinaryBuilder.use_ccache is true
            BinaryBuilder.use_ccache && @test !occursin("ccache", read(joinpath(bin_path, "gfortran"), String))
        end
        platform = Linux(:x86_64, libc=:musl, compiler_abi=CompilerABI(cxxstring_abi=:cxx03))
        mktempdir() do bin_path
            generate_compiler_wrappers!(platform; bin_path = bin_path)
            gcc = read(joinpath(bin_path, "gcc"), String)
            # Make sure the C++ string ABI is set as expected
            @test occursin("-D_GLIBCXX_USE_CXX11_ABI=0", gcc)
            # Make sure the unsafe flags check is there
            @test occursin("You used one or more of the unsafe flags", gcc)
        end
        platform = Linux(:x86_64, libc=:musl, compiler_abi=CompilerABI(cxxstring_abi=:cxx11))
        mktempdir() do bin_path
            generate_compiler_wrappers!(platform; bin_path = bin_path, allow_unsafe_flags = true)
            gcc = read(joinpath(bin_path, "gcc"), String)
            # Make sure the C++ string ABI is set as expected
            @test occursin("-D_GLIBCXX_USE_CXX11_ABI=1", gcc)
            # Make sure the unsafe flags check is not there in this case
            @test !occursin("You used one or more of the unsafe flags", gcc)
        end
        platform = FreeBSD(:x86_64)
        mktempdir() do bin_path
            generate_compiler_wrappers!(platform; bin_path = bin_path, compilers = [:c, :rust, :go])
            clang = read(joinpath(bin_path, "clang"), String)
            # Check link flags
            @test occursin("-L/opt/$(triplet(platform))/$(triplet(platform))/lib", clang)
            @test occursin("fuse-ld=$(triplet(platform))", clang)
            # Other compilers
            @test occursin("GOOS=\"freebsd\"", read(joinpath(bin_path, "go"), String))
            @test occursin("--target=x86_64-unknown-freebsd", read(joinpath(bin_path, "rustc"), String))
        end
        platform      = Linux(:x86_64, libc=:musl, compiler_abi=CompilerABI(cxxstring_abi=:cxx03))
        host_platform = Linux(:x86_64, libc=:musl, compiler_abi=CompilerABI(cxxstring_abi=:cxx11))
        mktempdir() do bin_path
            @test_throws ErrorException generate_compiler_wrappers!(platform; bin_path = bin_path, host_platform = host_platform)
        end
        platform      = Linux(:x86_64, libc=:musl)
        host_platform = Linux(:x86_64, libc=:musl, compiler_abi=CompilerABI(cxxstring_abi=:cxx03))
        mktempdir() do bin_path
            @test_throws ErrorException generate_compiler_wrappers!(platform; bin_path = bin_path, host_platform = host_platform)
        end
    end
end
