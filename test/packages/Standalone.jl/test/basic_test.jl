@testitem "doubling" begin
    @test Standalone.double(3) == 6
end

@testitem "doubling again" tags=[:more] begin
    @test Standalone.double(0) == 0
end
