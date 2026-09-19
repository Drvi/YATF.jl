@testitem "add works" tags=[:fast] begin
    using Basic
    @test Basic.add(1, 2) == 3
end

@testitem "mul works" tags=[:fast, :math] begin
    using Basic
    @test Basic.mul(2, 3) == 6
end

@testitem "uses setup" begin
    using BasicSetup
    @test BasicSetup.total() == 6
end
