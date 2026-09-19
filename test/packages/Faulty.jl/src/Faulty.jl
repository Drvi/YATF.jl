module Faulty
marker(name) = joinpath(get(ENV, "YATF_FAULTY_DIR", tempdir()), "yatf_" * name)
end
