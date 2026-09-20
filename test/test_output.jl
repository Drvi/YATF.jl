# Everything a run prints goes through one writer. These tests run a real suite in
# a subprocess, with the monitor printing as fast as it can and several workers
# relaying output at once, and check that no two writers ever landed on the same
# line.

using YATFWorkers: YATFWorkers

@testset "run output" begin
    work = mktempdir()
    out = joinpath(work, "run.log")
    script = joinpath(work, "run.jl")
    write(script, """
    push!(LOAD_PATH, $(repr(dirname(@__DIR__))))
    using YATF
    YATF.runtests($(repr(fixture("Basic.jl"))); workers=3, logs=:eager,
                  monitor=true, monitor_interval=0)
    """)
    ok = success(pipeline(ignorestatus(addenv(`$(Base.julia_cmd()) --startup-file=no $script`,
                                              "YATF_RUNSTATE_DIR" => joinpath(work, "runs")));
                          stdout=out, stderr=out))
    log = read(out, String)
    ok || @info "the output fixture failed; its output was:\n$log"
    @test ok
    lines = split(log, '\n')

    @testset "every item announces its start and its end" begin
        starts = filter(l -> occursin("· RUN", l), lines)
        dones  = filter(l -> occursin("· DONE", l), lines)
        @test length(starts) == 6
        @test length(dones) == 6
        # Blue while it runs, then the colour of how it went — every item in this
        # fixture passes.
        for l in starts
            @test occursin(
                Regex("^$(YATF.MARK_INDENT)$(YATFWorkers.MARK_RUNNING) w\\d+ · " *
                      "\\d\\d:\\d\\d:\\d\\d · RUN  · \\d/6 · \".+\"\\s+· at \\S+:\\d+\$"), l)
        end
        for l in dones
            @test occursin(
                Regex("^$(YATF.MARK_INDENT)$(YATFWorkers.MARK_PASSED) w\\d+ · " *
                      "\\d\\d:\\d\\d:\\d\\d · DONE · \\d/6 · \".+\"\\s+· PASS · "), l)
            @test occursin("maxrss", l)
        end
    end

    @testset "every line a worker or the run writes lines up" begin
        # One shape for the lot: glyph, who, when, what. The glyphs are all two
        # columns wide, so `w1 |` lands in the same place whichever kind of line
        # it is — which is the only reason a log of them is readable.
        heads = filter(l -> occursin(r" w\d+ · \d\d:\d\d:\d\d · ", l), lines)
        @test !isempty(heads)
        @test all(l -> startswith(l, YATF.MARK_INDENT), heads)
        marks = unique(first(split(strip(l))) for l in heads)
        known = Set([YATF.MARK_WORKER, YATF.MARK_INFO, YATF.LINE_MARKS...])
        @test issubset(marks, known)
        # This fixture starts workers, runs items that pass, and reports.
        @test YATF.MARK_WORKER in marks
        @test YATFWorkers.MARK_RUNNING in marks
        @test YATFWorkers.MARK_PASSED in marks
        # ...and the column `w<n>` starts in is the same on all of them.
        cols = unique(length(SubString(l, 1, prevind(l, first(findfirst(r" w\d+ · ", l))))) for l in heads)
        @test length(cols) == 1
    end

    @testset "the run reports on itself when there is no terminal" begin
        status = filter(l -> occursin("· INFO ", l), lines)
        @test !isempty(status)
        @test all(l -> startswith(l, YATF.MARK_INDENT * YATF.MARK_INFO * " w0" * YATFWorkers.FIELD), status)
        @test any(l -> occursin("mem ", l), status)
        @test any(l -> occursin("load ", l), status)   # CPU load, as well as memory
        @test any(l -> occursin("workers", l), status)
        @test any(l -> occursin("tree mem", l), status)
        @test any(l -> occursin("(max ", l), status)
    end

    @testset "a run with no workers concludes without claiming one" begin
        _, solo = capture_run() do
            run_states(fixture("Basic.jl"); workers=0, logs=:issues, monitor=false)
        end
        @test occursin("in this process", solo)
        @test !occursin("on 1 worker", solo)
    end

    @testset "a path is shortened on the way out, not on the way in" begin
        root = "/some/where/MyPkg"
        text = "Error During Test at $root/test/a_test.jl:7\n  @ $root/test/b_test.jl:2\n"
        short = YATF.strip_root(text, root)
        @test occursin("at test/a_test.jl:7", short)
        @test occursin("@ test/b_test.jl:2", short)
        @test !occursin(root, short)
        # The stacktrace printer writes the home directory as `~`, so the same
        # path arrives spelled two ways and both come off.
        home = homedir()
        under = joinpath(home, "proj", "MyPkg")
        both = "a $(under)/test/x.jl:1 and ~/proj/MyPkg/test/y.jl:2"
        @test YATF.strip_root(both, under) == "a test/x.jl:1 and test/y.jl:2"
        # Nothing to strip, nothing changed.
        @test YATF.strip_root(text, "") == text
        @test YATF.strip_root("no paths here", root) == "no paths here"
    end

    @testset "a worker's last line says what it did, not what the slot did" begin
        # One worker, three items: the count belongs to the process that ran them.
        _, out = capture_run() do
            run_states(fixture("Basic.jl"); workers=1, logs=:issues, monitor=false)
        end
        exits = filter(l -> occursin("· EXIT", l), collect(eachsplit(out, '\n')))
        @test length(exits) == 1
        @test occursin("6 items", only(exits))
        # A graceful shutdown is not a kill: that word is reserved for a worker
        # the run put down, and the two must stay distinguishable. It is also not
        # "DONE", which is an item finishing, nor "LOST", which is a worker that
        # died on its own — four words, none of them a glance away from another.
        @test !occursin("KILL", out)
        @test !occursin("LOST", out)
        @test count(l -> occursin("· UP ", l), collect(eachsplit(out, '\n'))) == 1
    end

    @testset "the name column is chosen from the names the run will print" begin
        nw(names; columns=0) = YATFWorkers.name_width(names; columns)
        qw = YATFWorkers.quoted_width
        widest(names) = maximum(qw, names)

        short = ["item $i" for i in 1:100]
        # They all fit, so they all line up and nothing overflows.
        @test nw(short) == widest(short)
        @test count(n -> qw(n) > nw(short), short) == 0

        # Two long names among a hundred short ones do not buy forty columns of
        # blanks on every line.
        outliers = vcat(short, ["a much longer outlier name $i" for i in 1:2])
        @test nw(outliers) < widest(outliers)
        @test count(n -> qw(n) > nw(outliers), outliers) <= 3

        # A tail that is only a little longer than the rest is covered instead.
        tight = ["name of length about $i" for i in 1:50]
        @test nw(tight) == widest(tight)

        # Whatever the distribution, the overflow stays a tail.
        for names in (short, outliers, tight, vcat(short, ["x"^150]),
                      vcat(short[1:90], ["slightly longer name $i" for i in 1:10]))
            over = count(n -> qw(n) > nw(names), names)
            @test over <= max(YATFWorkers.NAME_OUTLIER_ALLOWANCE,
                              length(names) ÷ YATFWorkers.NAME_OUTLIER_SHARE)
        end

        # A terminal narrows the column; a narrow one does not squeeze it away.
        long = ["a considerably longer test item name $i" for i in 1:100]
        @test nw(long; columns=200) > nw(long; columns=120) > nw(long; columns=80)
        @test nw(long; columns=40) >= YATFWorkers.MIN_NAME_WIDTH
        @test nw(long) <= YATFWorkers.MAX_NAME_WIDTH
        @test nw(String[]) >= YATFWorkers.MIN_NAME_WIDTH
        @test nw(["just the one"]) == qw("just the one")

        # The width it counts on is the width the line actually takes.
        for n in ["plain", "with \"quotes\"", "emoji 🎉", "tab\there", "dollar \$x", ""]
            @test qw(n) == textwidth(sprint(YATFWorkers.print_quoted, n))
        end
    end

    @testset "a log path is built exactly as `string` would build it" begin
        # The digits go into the string's bytes by hand, which is only worth doing
        # if it cannot disagree with the obvious way of writing it.
        prefix = "/tmp/yatf_abcdef/item_"
        for index in (1, 9, 10, 99, 100, 2000, 12345), attempt in (1, 2, 9, 10, 127)
            @test YATF.item_log_path(prefix, index, attempt) ==
                string(prefix, index, "_", attempt, ".log")
        end
    end

    @testset "every [YATF] line starts in the same column" begin
        # The things YATF says that run to more than one line are bracketed, and
        # the gutter takes the two columns the one-line ones leave blank — so the
        # prefix is in one column down the whole log, bracketed or not.
        # Counted in characters: a bracket's corner is more than one byte wide.
        column(l) = length(SubString(l, 1, prevind(l, first(findfirst("[YATF]", l))))) + 1
        cols = unique(column(l) for l in lines if occursin("[YATF]", l))
        @test length(cols) == 1
        @test only(cols) == length(YATF.GUTTER) + 1
        # ...and the multi-line ones really are drawn as blocks.
        @test any(l -> startswith(l, "┌ [YATF] "), lines)
        @test count(l -> startswith(l, "└"), lines) >= 1
    end

    @testset "no two writers share a line" begin
        # A marker that starts a line must never appear in the middle of one:
        # that is what interleaved writes look like.
        for marker in ("[YATF]", "· RUN", "· DONE", "Captured logs:")
            for l in lines
                occursin(marker, l) || continue
                @test count(marker, l) == 1
                if marker == "[YATF]"
                    # At the start of its line, after the gutter or after a
                    # bracket's corner. Anywhere else is two writers on one line.
                    @test startswith(l, YATF.GUTTER * "[YATF]") ||
                        occursin(r"^[┌│└] \[YATF\]", l)
                end
            end
        end
        # Nothing may be printed after a worker's relayed line on the same line.
        for l in lines
            occursin(r" w\d+ · \d\d:\d\d:\d\d · ", l) || continue
            @test count(r"\sw\d+ · ", l) == 1
        end
    end

    @testset "an item's failures and logs arrive as one bracketed block" begin
        work2 = mktempdir()
        out2 = joinpath(work2, "run.log")
        script2 = joinpath(work2, "run.jl")
        write(script2, """
        push!(LOAD_PATH, $(repr(dirname(@__DIR__))))
        using YATF
        try
            YATF.runtests($(repr(fixture("Faulty.jl"))); workers=1, logs=:issues, monitor=false,
                          name="fails after logging")
        catch
        end
        """)
        run(pipeline(ignorestatus(addenv(`$(Base.julia_cmd()) --startup-file=no $script2`,
                                         "YATF_RUNSTATE_DIR" => joinpath(work2, "runs"),
                                         "YATF_FAULTY_DIR" => work2));
                     stdout=out2, stderr=out2))
        # The item's own block, not the run header's or the conclusion's: those are
        # bracketed too, and what this is about is that one item's output is one
        # block.
        all_lines = split(read(out2, String), '\n')
        first_line = findfirst(l -> startswith(l, "┌ [1/1] FAIL "), all_lines)
        @test first_line !== nothing
        last_line = findnext(l -> startswith(l, "└"), all_lines, first_line)
        block = all_lines[first_line:last_line]
        @test all(l -> startswith(l, "┌") || startswith(l, "│") || startswith(l, "└"), block)
        @test startswith(last(block), "└ @ test/faults_test.jl:")
        # the item's failure, its captured output and its own log records, nested
        @test any(l -> occursin("Expression: 1 == 2", l), block)
        @test any(l -> occursin("┌ Captured logs", l), block)
        @test any(l -> occursin("some output before the failure", l), block)
        @test any(l -> occursin("Warning: something looked wrong", l), block)
        # nothing about this item is printed outside the block
        others = filter(l -> !isempty(l) && !startswith(l, "┌") && !startswith(l, "│") &&
                             !startswith(l, "└"), split(read(out2, String), '\n'))
        @test !any(l -> occursin("Expression: 1 == 2", l), others)
    end

    @testset "a name is written exactly as `repr` would write it" begin
        # The item line skips `repr` when a name holds nothing to escape, which is
        # almost every name. The two must not disagree, or a name with a quote in it
        # comes out wrong in every line that mentions it.
        for name in ["plain", "with space", "has \"quotes\"", "back\\slash", "dollar \$x",
                     "tab\there", "newline\nhere", "unicode é", "emoji 🎉", "",
                     "\e[1mnot an escape sequence"]
            io = IOBuffer()
            width = YATFWorkers.print_quoted(io, name)
            written = String(take!(io))
            @test written == repr(name)
            @test width == textwidth(written)
        end
    end

    @testset "no terminal control sequences when there is no terminal" begin
        @test !occursin("\e[2K", log)
        @test !occursin("\e[", log)
    end
end
