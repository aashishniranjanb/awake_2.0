// Self-checking serialized-CSA bench.
// Convention: edge S is the posedge at which sample_valid (or a restart) is
// sampled. After edges S..S+4 the CSA is busy with the old score held;
// after edge S+5 score_valid=1 and stress_score = golden(operands).
module tb_csa;
    reg clk = 0, rst_n = 0, enable = 0, sample_valid = 0, cfg_write = 0;
    reg [7:0] s0 = 0, s1 = 0, s2 = 0, s3 = 0, s4 = 0;
    reg [7:0] w0 = 0, w1 = 0, w2 = 0, w3 = 0, w4 = 0;
    reg [3:0] shift_factor = 6;
    wire [7:0] stress_score;
    wire score_valid, busy;
    integer errors = 0, n, k;

    crop_stress_accelerator dut(.clk(clk), .rst_n(rst_n), .enable(enable),
        .sample_valid(sample_valid), .cfg_write(cfg_write),
        .moisture(s0), .leaf_temp(s1), .humidity(s2), .air_temp(s3), .light(s4),
        .w_moisture(w0), .w_leaftemp(w1), .w_humidity(w2), .w_airtemp(w3), .w_light(w4),
        .shift_factor(shift_factor), .stress_score(stress_score),
        .score_valid(score_valid), .busy(busy));

    always #5 clk = ~clk;
    task tick; @(negedge clk); endtask

    function [7:0] golden;
        input dummy;
        reg [18:0] sum;
        begin
            sum = s0*w0 + s1*w1 + s2*w2 + s3*w3 + s4*w4;
            sum = sum >> shift_factor;
            golden = (sum > 255) ? 8'd255 : sum[7:0];
        end
    endfunction

    task fail(input [8*48-1:0] msg);
        begin
            $display("FAIL: %0s (score=%0d valid=%b busy=%b)", msg, stress_score, score_valid, busy);
            errors = errors + 1;
        end
    endtask

    task expect_busy(input [7:0] old, input [8*48-1:0] msg);
        begin if (busy !== 1 || score_valid !== 0 || stress_score !== old) fail(msg); end
    endtask

    // Start at the next edge, check the 4 busy cycles, then the result.
    task run_expect(input [7:0] exp, input [8*48-1:0] msg);
        reg [7:0] old;
        begin
            old = stress_score;
            sample_valid = 1; tick; sample_valid = 0;          // edge S
            expect_busy(old, msg);
            for (k = 1; k <= 4; k = k + 1) begin tick; expect_busy(old, msg); end
            tick;                                              // edge S+5
            if (score_valid !== 1 || busy !== 0 || stress_score !== exp) begin
                $display("FAIL: %0s expected %0d got %0d valid=%b", msg, exp, stress_score, score_valid);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        tick; rst_n = 1; tick;
        if (score_valid !== 0 || busy !== 0 || stress_score !== 0) fail("reset idle");
        sample_valid = 1; tick; sample_valid = 0;
        if (busy !== 0 || score_valid !== 0) fail("disabled CSA ignores start");
        enable = 1; tick;

        run_expect(8'd0, "zero inputs");

        {s0, s1, s2, s3, s4} = {5{8'd255}}; {w0, w1, w2, w3, w4} = {5{8'd255}};
        shift_factor = 0;  run_expect(8'd255, "max sum 325125 saturates");
        shift_factor = 11; run_expect(8'd158, "325125 >> 11 = 158");
        shift_factor = 10; run_expect(8'd255, "325125 >> 10 = 317 saturates");
        shift_factor = 15; run_expect(8'd9,   "325125 >> 15 = 9");
        if (dut.acc !== 19'd260100) fail("accumulator retains full 19-bit width");

        // lane isolation: one lane at a time, all others zero
        for (n = 0; n < 5; n = n + 1) begin
            {s0, s1, s2, s3, s4} = 0; {w0, w1, w2, w3, w4} = 0; shift_factor = 6;
            case (n)
                0: begin s0 = 8'd11; w0 = 8'd64; end
                1: begin s1 = 8'd22; w1 = 8'd64; end
                2: begin s2 = 8'd33; w2 = 8'd64; end
                3: begin s3 = 8'd44; w3 = 8'd64; end
                4: begin s4 = 8'd55; w4 = 8'd64; end
            endcase
            run_expect(golden(0), "single-lane isolation");
        end

        // capture while busy restarts with the newer sample
        {s0, s1, s2, s3, s4} = {8'd10, 8'd20, 8'd30, 8'd40, 8'd50};
        {w0, w1, w2, w3, w4} = {8'd13, 8'd13, 8'd13, 8'd13, 8'd12}; shift_factor = 6;
        run_expect(golden(0), "baseline score");
        sample_valid = 1; tick; sample_valid = 0; tick; tick;
        s0 = 8'd200; s4 = 8'd250;
        run_expect(golden(0), "capture while busy restarts");

        // config write mid-compute restarts with the new weights
        sample_valid = 1; tick; sample_valid = 0; tick; tick;
        cfg_write = 1; tick; cfg_write = 0; w2 = 8'd100;      // weight changes at the write edge
        expect_busy(stress_score, "restarted after cfg write");
        for (k = 1; k <= 4; k = k + 1) begin
            if (score_valid !== 0) fail("no early completion after cfg restart");
            tick;
        end
        if (score_valid !== 0) fail("cfg restart: still busy at R+4");
        tick;
        if (score_valid !== 1 || stress_score !== golden(0)) fail("cfg write mid-compute uses new weights");

        // config write on the same edge as capture: new weights used
        sample_valid = 1; cfg_write = 1; tick; sample_valid = 0; cfg_write = 0; w3 = 8'd7; shift_factor = 5;
        for (k = 1; k <= 5; k = k + 1) tick;
        if (score_valid !== 1 || stress_score !== golden(0)) fail("capture+cfg write same edge coherent");

        // restart on the final edge wins over completion
        sample_valid = 1; tick; sample_valid = 0;
        for (k = 1; k <= 4; k = k + 1) tick;
        cfg_write = 1; tick; cfg_write = 0; w0 = 8'd1;
        if (score_valid !== 0 || busy !== 1) fail("restart on final edge wins");
        for (k = 1; k <= 4; k = k + 1) tick;
        tick;
        if (score_valid !== 1 || stress_score !== golden(0)) fail("completes 5 edges after late restart");

        // idle config write does not recompute or invalidate
        n = stress_score;
        cfg_write = 1; tick; cfg_write = 0; w1 = 8'd255;
        if (busy !== 0 || score_valid !== 1 || stress_score !== n) fail("idle cfg write ignored");

        // abort: enable low mid-compute clears valid, holds score
        sample_valid = 1; tick; sample_valid = 0; tick; tick;
        enable = 0; tick;
        if (busy !== 0 || score_valid !== 0 || stress_score !== n) fail("abort on !enable");
        enable = 1; tick;
        if (busy !== 0 || score_valid !== 0) fail("no spontaneous restart after abort");

        // random golden-model comparison
        for (n = 0; n < 2000; n = n + 1) begin
            {s0, s1, s2, s3, s4} = {$random, $random};
            {w0, w1, w2, w3, w4} = {$random, $random};
            shift_factor = $random;
            run_expect(golden(0), "random vector");
        end

        // async reset mid-compute
        sample_valid = 1; tick; sample_valid = 0; tick;
        rst_n = 0; #1;
        if (busy !== 0 || score_valid !== 0 || stress_score !== 0) fail("async reset mid-compute");
        rst_n = 1;

        if (errors == 0) $display("TEST PASSED tb_csa");
        else $fatal(1, "tb_csa: %0d errors", errors);
        $finish;
    end
endmodule
