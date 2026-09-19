module TimeSetup

# Dates is the package's second test-only dependency, and DepSetup is another
# setup: a setup module resolves both against the environment the run built, the
# same way a test item does.
using Dates
using DepSetup

const EPOCH = DateTime(2020, 1, 1)

stamp() = EPOCH + Day(1)
seeded() = (stamp(), DepSetup.fixed())

end
