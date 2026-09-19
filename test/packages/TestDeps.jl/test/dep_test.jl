@testitem "a test-only dependency is loadable" begin
    using Random          # declared only in [extras]/[targets], not in [deps]
    rng = Xoshiro(1234)
    @test rand(rng) isa Float64
    @test TestDeps.pick([1, 2, 3]) == 1
end
