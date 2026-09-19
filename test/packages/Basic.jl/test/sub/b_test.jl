@testitem "chain one" chain=:seq begin
    @test true
end

@testitem "chain two" chain=:seq begin
    @test true
end

@testitem "slow thing" tags=[:slow] timeout=2*60 begin
    @test true
end
