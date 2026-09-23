"""
The debugger behind `YATF.debug`. A separate module so that Debugger.jl is loaded by
a session that asks to step through a test item, and by no test run.
"""
module YATFDebuggerExt

using Debugger: Debugger

# The item's body, a function of no arguments, entered the way `Debugger.@enter`
# enters a call: stopped at its first statement, with the terminal handed over.
enter(body) = Debugger.@enter body()

end
