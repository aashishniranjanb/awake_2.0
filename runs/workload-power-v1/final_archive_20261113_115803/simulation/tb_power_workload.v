`timescale 1ns / 1ps

module tb_power_workload;

    // IPM states
    localparam SLEEP    = 2'b00;
    localparam MONITOR  = 2'b01;
    localparam WARNING  = 2'b10;
    localparam CRITICAL = 2'b11;

    reg clk = 0;
    reg rst_n = 0;

    reg [7:0] m_addr = 0;
    reg [7:0] m_wdata = 0;
    reg m_we = 0;
    reg m_re = 0;

    reg sample_valid = 0;
    reg [7:0] moisture = 20;
    reg [7:0] leaf_temp = 60;
    reg [7:0] humidity = 30;
    reg [7:0] air_temp = 30;
    reg [7:0] light = 30;
    reg [7:0] battery = 200;
    reg wake_timer = 0;

    wire [7:0] m_rdata;
    wire [3:0] leaf_output;
    wire [1:0] ipm_state;
    wire domain2_pwr_en;
    wire domain3_pwr_en;
    wire comm_en_out;
    wire [9:0] adc_mode_vector;

    integer errors = 0;
    integer i;

    // 50 MHz clock: 20 ns period
    always #10 clk = ~clk;

    agrisense_ipms_top uut (
        .clk(clk),
        .rst_n(rst_n),
        .m_addr(m_addr),
        .m_wdata(m_wdata),
        .m_we(m_we),
        .m_re(m_re),
        .m_rdata(m_rdata),
        .sample_valid(sample_valid),
        .moisture(moisture),
        .leaf_temp(leaf_temp),
        .humidity(humidity),
        .air_temp(air_temp),
        .light(light),
        .battery(battery),
        .wake_timer(wake_timer),
        .leaf_output(leaf_output),
        .ipm_state(ipm_state),
        .domain2_pwr_en(domain2_pwr_en),
        .domain3_pwr_en(domain3_pwr_en),
        .comm_en_out(comm_en_out),
        .adc_mode_vector(adc_mode_vector)
    );

    // Complete gate-level DUT hierarchy
    initial begin
        $dumpfile("runs/workload-power-v1/simulation/workload.vcd");
        $dumpvars(0, tb_power_workload);
    end

    task check_state;
        input [1:0] expected;
        input [8*48-1:0] description;
        begin
            if (ipm_state !== expected) begin
                $display(
                    "FAIL: %0s expected=%b actual=%b time=%0t",
                    description, expected, ipm_state, $time
                );
                errors = errors + 1;
            end else begin
                $display(
                    "PASS: %0s state=%b time=%0t",
                    description, ipm_state, $time
                );
            end
        end
    endtask

    task write_register;
        input [7:0] address;
        input [7:0] data;
        begin
            @(negedge clk);
            m_addr = address;
            m_wdata = data;
            m_we = 1'b1;

            @(negedge clk);
            m_we = 1'b0;
        end
    endtask

    task send_sample;
        input [7:0] m;
        input [7:0] lt;
        begin
            @(negedge clk);
            moisture = m;
            leaf_temp = lt;
            sample_valid = 1'b1;

            @(negedge clk);
            sample_valid = 1'b0;

            // Allow synchronization, acceptance, CSA and classification
            repeat (14) @(negedge clk);
        end
    endtask

    task wake_system;
        begin
            @(negedge clk);
            wake_timer = 1'b1;

            @(negedge clk);
            wake_timer = 1'b0;

            repeat (4) @(negedge clk);
        end
    endtask

    task configure_base;
        begin
            write_register(8'h10, 8'd64);
            write_register(8'h52, 8'd1);
            write_register(8'h51, 8'd4);

            for (i = 8'h20; i <= 8'h24; i = i + 1)
                write_register(i, 8'd0);
        end
    endtask

    initial begin

        $display("==============================================");
        $display(" AWAKE GATE-LEVEL WORKLOAD POWER SIMULATION");
        $display(" Clock period: 20 ns / 50 MHz");
        $display("==============================================");

        // Reset
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        check_state(SLEEP, "Reset to SLEEP");

        // SLEEP workload
        send_sample(8'd200, 8'd200);
        repeat (20) @(negedge clk);

        check_state(SLEEP, "Remain in SLEEP");

        // Wake to MONITOR
        wake_system;
        check_state(MONITOR, "Wake to MONITOR");

        // Base configuration
        configure_base;

        // MONITOR workload
        send_sample(8'd20, 8'd60);
        send_sample(8'd20, 8'd60);
        send_sample(8'd120, 8'd60);

        // Program decision tree thresholds
        write_register(8'h60, 8'd100);
        write_register(8'h62, 8'hFF);
        write_register(8'h65, 8'd100);
        write_register(8'h63, 8'd50);

        // Settle and trigger critical condition
        send_sample(8'd20, 8'd60);
        send_sample(8'd20, 8'd60);
        send_sample(8'd150, 8'd60);

        check_state(CRITICAL, "Escalation to CRITICAL");

        if (!(domain2_pwr_en && domain3_pwr_en && comm_en_out)) begin
            $display("FAIL: CRITICAL power domains not enabled");
            errors = errors + 1;
        end

        // CRITICAL -> WARNING
        send_sample(8'd60, 8'd60);
        check_state(WARNING, "Recovery to WARNING");

        // WARNING -> MONITOR
        send_sample(8'd60, 8'd10);
        check_state(MONITOR, "Recovery to MONITOR");

        // Idle MONITOR workload
        repeat (100) @(negedge clk);

        // Invalid sample workload
        @(negedge clk);
        moisture = 8'd250;
        sample_valid = 1'b0;
        repeat (30) @(negedge clk);

        // Reset during operation
        @(negedge clk);
        rst_n = 1'b0;
        repeat (3) @(negedge clk);

        check_state(SLEEP, "Reset during activity");

        if (errors == 0)
            $display("WORKLOAD TEST PASSED");
        else
            $display("WORKLOAD TEST FAILED: %0d errors", errors);

        // Capture final transitions before closing VCD
        repeat (10) @(negedge clk);

        $dumpoff;
        $finish;
    end

    // State trace for later analysis
    always @(ipm_state) begin
        $display(
            "STATE_CHANGE time=%0t state=%b D2=%b D3=%b COMM=%b",
            $time, ipm_state,
            domain2_pwr_en, domain3_pwr_en, comm_en_out
        );
    end

endmodule
