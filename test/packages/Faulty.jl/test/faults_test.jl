@testitem "passes" tags=[:ok] begin
    @test true
end

@testitem "fails" tags=[:fail] begin
    @test 1 == 2
end

@testitem "errors" tags=[:error] begin
    error("boom")
end

@testitem "throws outside a test" tags=[:error] begin
    x = [1]
    x[5]
end

@testitem "hangs" tags=[:hang] timeout=3 begin
    sleep(600)
    @test true
end

@testitem "kills its worker" tags=[:die] begin
    exit(7)
end

@testitem "returns something unserializable" tags=[:unserializable] begin
    struct Unsendable <: Exception
        f::Function
    end
    throw(Unsendable(x -> x + 1))
end

@testitem "skipped statically" tags=[:skip] skip=true begin
    @test false
end

@testitem "skipped dynamically" tags=[:skip] skip=(1 + 1 == 2) begin
    @test false
end

@testitem "passes on the second try" tags=[:retry] retries=1 begin
    using Faulty
    path = Faulty.marker("retry")
    if isfile(path)
        @test true
    else
        write(path, "seen")
        @test false
    end
end

@testitem "chain start kills the worker" tags=[:chaindie] chain=:dies begin
    exit(9)
end

@testitem "chain rest must not run" tags=[:chaindie] chain=:dies begin
    using Faulty
    write(Faulty.marker("must_not_run"), "ran")
    @test true
end

@testitem "logs a lot" tags=[:logs] begin
    println("this is stdout from the item")
    @info "this is a log message"
    @test true
end

@testitem "knows it is in a test item" tags=[:scope] begin
    using YATF
    info = YATF.current_testitem()
    @test info !== nothing
    @test info.name == "knows it is in a test item"
    @test YATF.in_testitem()
    @test YATF.in_yatf_run()
    @test fetch(Threads.@spawn YATF.in_testitem())   # spawned tasks inherit the scope
end

@testitem "survives two dead workers" tags=[:abort] retries=2 begin
    using Faulty
    path = Faulty.marker("abort_count")
    n = isfile(path) ? parse(Int, read(path, String)) : 0
    write(path, string(n + 1))
    n < 2 && ccall(:abort, Cvoid, ())   # SIGABRT: the process dies where it stands
    @test n == 2
end

@testitem "fails after logging" tags=[:logs] begin
    println("some output before the failure")
    @warn "something looked wrong"
    @test 1 == 2
end

@testitem "its own log lines go through the coordinator" tags=[:routing] begin
    @test true
end
