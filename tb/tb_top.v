`include "agrisense_defs.vh"
// Self-checking end-to-end bench for agrisense_ipms_top through the register bus
// and sensor pins only (no forcing). Checks quiet reset, safe DT defaults,
// MONITOR -> WARNING -> CRITICAL -> WARNING -> MONITOR, sample-to-score
// coherence, event re-arm without thrash, register readback and reset.
module tb_top;
    reg clk = 0, rst_n = 0;
    reg [7:0] m_addr = 0, m_wdata = 0;
    reg m_we = 0, m_re = 0;
    wire [7:0] m_rdata;
    reg sample_valid = 0;
    reg [7:0] moisture = 20, leaf_temp = 60, humidity = 30, air_temp = 30, light = 30, battery = 200;
    reg wake_timer = 0;
    wire [3:0] leaf_output;
    wire [1:0] ipm_state;
    wire d2, d3, comm;
    wire [9:0] adc_mode_vector;
    integer errors = 0, i, events;

    agrisense_ipms_top uut(.clk(clk), .rst_n(rst_n), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_we(m_we), .m_re(m_re), .m_rdata(m_rdata), .sample_valid(sample_valid),
        .moisture(moisture), .leaf_temp(leaf_temp), .humidity(humidity), .air_temp(air_temp),
        .light(light), .battery(battery), .wake_timer(wake_timer), .leaf_output(leaf_output),
        .ipm_state(ipm_state), .domain2_pwr_en(d2), .domain3_pwr_en(d3), .comm_en_out(comm),
        .adc_mode_vector(adc_mode_vector));

    always #5 clk = ~clk;
    always @(posedge clk) if (uut.stress_event) events = events + 1;

    task fail(input [8*56-1:0] msg);
        begin $display("FAIL: %0s (state=%0d leaf=%b score=%0d)", msg, ipm_state, leaf_output,
                       uut.stress_score_raw); errors = errors + 1; end
    endtask

    task wr(input [7:0] a, input [7:0] d);
        begin @(negedge clk); m_addr = a; m_wdata = d; m_we = 1; @(negedge clk); m_we = 0; end
    endtask

    task rd_expect(input [7:0] a, input [7:0] e);
        begin
            @(negedge clk); m_addr = a; m_re = 1; #1;
            if (m_rdata !== e) begin
                $display("FAIL: bus read 0x%h = 0x%h expected 0x%h", a, m_rdata, e); errors = errors + 1;
            end
            m_re = 0;
        end
    endtask

    // one-cycle sample_valid with data held stable; then settle
    task sample(input [7:0] m, input [7:0] lt);
        begin
            @(negedge clk); moisture = m; leaf_temp = lt; sample_valid = 1;
            @(negedge clk); sample_valid = 0;
            repeat (14) @(negedge clk); // 3 sync/accept + 5 CSA + hysteresis
        end
    endtask

    task wake;
        begin
            @(negedge clk); wake_timer = 1; @(negedge clk); wake_timer = 0;
            repeat (4) @(negedge clk);
        end
    endtask

    task expect_state(input [1:0] s, input [8*56-1:0] msg);
        begin if (ipm_state !== s) fail(msg); end
    endtask

    // shared configuration: score == moisture (w_moisture = 64, shift 6), any crossover
    // fires (threshold 1), DECDE k_fast = 0 so a step crosses on the next sample.
    task base_config;
        begin
            wr(8'h10, 8'd64); wr(8'h52, 8'd1); wr(8'h51, 8'd4);
            for (i = 8'h20; i <= 8'h24; i = i + 1) wr(i, 8'd0);
        end
    endtask

    initial begin
        events = 0;
        repeat (3) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);

        // ---------- 1. quiet reset: idle, no outputs, no events ----------
        expect_state(`IPM_SLEEP, "reset -> SLEEP");
        if (d2 || d3 || comm || leaf_output !== 0 || adc_mode_vector !== 0) fail("reset outputs quiet");
        sample(8'd200, 8'd200);
        expect_state(`IPM_SLEEP, "sample ignored in SLEEP");
        if (uut.sample_available !== 0) fail("SLEEP sample must not be accepted");

        // ---------- 2. default config: wake + varied samples, never escalates ----------
        wake; expect_state(`IPM_MONITOR, "wake -> MONITOR");
        for (i = 0; i < 6; i = i + 1) sample(i * 40, 255 - i * 40);
        expect_state(`IPM_MONITOR, "default vote_threshold=0 stays MONITOR");
        if (events !== 0) fail("default config produced stress events");

        // ---------- 3. default DT thresholds (0xFF) classify NORMAL ----------
        base_config;
        sample(8'd20, 8'd60); sample(8'd20, 8'd60);       // settle EMAs, no crossing
        sample(8'd120, 8'd60);                            // rising step -> crossover -> event
        if (ipm_state === `IPM_CRITICAL) fail("reset DT thresholds must not escalate");
        expect_state(`IPM_MONITOR, "safe DT defaults: WARNING exits after 2 valid NORMAL");
        if (events !== 1) fail("exactly one stress_event pulse expected");

        // ---------- 4. programmed tree: full escalation and recovery ----------
        // score >= 100 -> right subtree -> WATER/TEMP (severity 11)
        // score < 100, leaf_temp >= 50 -> LOW_STRESS (01); leaf_temp < 50 -> NORMAL
        wr(8'h60, 8'd100); wr(8'h62, 8'hFF); wr(8'h65, 8'd100); wr(8'h63, 8'd50);
        rd_expect(8'h60, 8'd100);
        sample(8'd20, 8'd60); sample(8'd20, 8'd60);
        events = 0;
        sample(8'd150, 8'd60);
        expect_state(`IPM_CRITICAL, "score 150 -> CRITICAL");
        if (!d2 || !d3 || !comm) fail("CRITICAL enables Domain 2/3 and comm");
        if (uut.stress_score_raw !== 8'd150) fail("score must equal accepted moisture 150");
        if (leaf_output !== 4'b1101) fail("air_temp 30 < T5 -> WATER_DOMINANT 1101");
        rd_expect(8'h18, 8'd150);
        rd_expect(8'h70, 8'b01_0000_11);
        rd_expect(8'hA0, 8'h03);
        rd_expect(8'h04, 8'd150);
        rd_expect(8'hA2, 8'd200);

        // sample-to-score coherence (serialized CSA): the new score appears exactly
        // 5 edges after the acceptance edge, equals f(held sample), and the old
        // score is held (valid low) in between.
        @(negedge clk); moisture = 8'd60; leaf_temp = 8'd60; sample_valid = 1;
        @(negedge clk); sample_valid = 0;
        while (uut.sampled_moisture !== 8'd60) begin
            @(posedge clk); #1;
            if (uut.stress_score_raw !== 8'd150) fail("score changed before its sample was accepted");
        end
        for (i = 1; i <= 5; i = i + 1) begin
            if (i < 5 && uut.csa_score_valid !== 1'b0) fail("score valid before 5-edge latency");
            if (i < 5 && uut.stress_score_raw !== 8'd150) fail("old score not held while busy");
            @(posedge clk); #1;
        end
        if (uut.csa_score_valid !== 1'b1 || uut.stress_score_raw !== 8'd60)
            fail("score valid 5 edges after acceptance and equals held sample");
        repeat (4) @(negedge clk);
        expect_state(`IPM_WARNING, "score 60, leaf 60 -> LOW_STRESS -> WARNING");
        if (!d2 || d3 || comm) fail("WARNING: Domain 2 only");
        if (leaf_output !== 4'b0100) fail("LOW_STRESS 0100");

        sample(8'd60, 8'd10);
        expect_state(`IPM_MONITOR, "leaf_temp 10 -> NORMAL x2 -> MONITOR");
        if (d2 || d3 || comm || leaf_output !== 0) fail("MONITOR isolates Domain 2 outputs");

        // no thrash: stay in MONITOR with no new crossings
        events = 0;
        sample(8'd60, 8'd10); sample(8'd60, 8'd10);
        expect_state(`IPM_MONITOR, "no re-entry without a new event");
        if (events !== 0) fail("re-arm: no events without new crossings");

        // ---------- 5. invalid samples: data changes without valid are ignored ----------
        @(negedge clk); moisture = 8'd250; repeat (10) @(negedge clk);
        if (uut.sampled_moisture !== 8'd60) fail("unqualified data must not be captured");

        // ---------- 6. reset during activity ----------
        sample(8'd20, 8'd60); sample(8'd200, 8'd60);
        expect_state(`IPM_CRITICAL, "re-escalated before reset");
        @(negedge clk); rst_n = 0; #1;
        expect_state(`IPM_SLEEP, "async reset -> SLEEP");
        if (d2 || d3 || comm || leaf_output !== 0 || adc_mode_vector !== 0) fail("reset clears outputs");
        @(negedge clk); rst_n = 1; @(negedge clk);
        rd_expect(8'h60, 8'hFF);
        rd_expect(8'h52, 8'h00);

        if (errors == 0) $display("TEST PASSED tb_top");
        else $fatal(1, "tb_top: %0d errors", errors);
        $finish;
    end
endmodule
