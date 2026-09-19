@testitem "a setup can use the package's test-only dependencies" begin
    using DepSetup
    # DepSetup itself imports Random, which TestDeps declares only for testing.
    @test DepSetup.draw() isa Float64
    @test DepSetup.fixed() === DepSetup.fixed()
    @test DepSetup.RNG isa DepSetup.Random.Xoshiro
end

@testitem "a setup can use another setup and a second test-only dependency" begin
    using TimeSetup
    @test TimeSetup.stamp() > TimeSetup.EPOCH
    # DepSetup is reached through TimeSetup, not by this item.
    stamp, draw = TimeSetup.seeded()
    @test stamp isa TimeSetup.DateTime
    @test draw isa Float64
end
