module DepSetup

# Random is a test-only dependency of TestDeps: it is in [extras]/[targets], not
# in [deps]. A setup module is loaded from `test/testsetups` as an implicit
# environment, so its own imports resolve against the environment the run built.
using Random

const RNG = Xoshiro(20250918)

draw() = rand(RNG)
fixed() = rand(Xoshiro(1))

end
