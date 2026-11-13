`timescale 1ns / 1ps

module tb_power_state;

    localparam SLEEP=2'b00, MONITOR=2'b01,
               WARNING=2'b10, CRITICAL=2'b11;

    reg clk=0, rst_n=0;
    reg [7:0] m_addr=0, m_wdata=0;
    reg m_we=0, m_re=0;
    reg sample_valid=0;
    reg [7:0] moisture=20, leaf_temp=60;
    reg [7:0] humidity=30, air_temp=30;
    reg [7:0] light=30, battery=200;
    reg wake_timer=0;

    wire [7:0] m_rdata;
    wire [3:0] leaf_output;
    wire [1:0] ipm_state;
    wire domain2_pwr_en, domain3_pwr_en, comm_en_out;
    wire [9:0] adc_mode_vector;

    reg [8*16-1:0] state_arg;
    reg [8*256-1:0] vcd_path;
    reg [1:0] expected_state;
    reg measuring=0;
    integer i, errors=0;

    always #10 clk=~clk;

    agrisense_ipms_top uut (
        .clk(clk), .rst_n(rst_n),
        .m_addr(m_addr), .m_wdata(m_wdata),
        .m_we(m_we), .m_re(m_re),
        .m_rdata(m_rdata),
        .sample_valid(sample_valid),
        .moisture(moisture), .leaf_temp(leaf_temp),
        .humidity(humidity), .air_temp(air_temp),
        .light(light), .battery(battery),
        .wake_timer(wake_timer),
        .leaf_output(leaf_output),
        .ipm_state(ipm_state),
        .domain2_pwr_en(domain2_pwr_en),
        .domain3_pwr_en(domain3_pwr_en),
        .comm_en_out(comm_en_out),
        .adc_mode_vector(adc_mode_vector)
    );

    task check_state;
        input [1:0] expected;
        begin
            if (ipm_state !== expected) begin
                $display("FAIL expected=%b actual=%b time=%0t",
                         expected, ipm_state, $time);
                $fatal(1, "Incorrect state");
            end
            $display("PASS state=%b time=%0t", ipm_state, $time);
        end
    endtask

    task write_register;
        input [7:0] address, data;
        begin
            @(negedge clk);
            m_addr=address;
            m_wdata=data;
            m_we=1;
            @(negedge clk);
            m_we=0;
        end
    endtask

    task send_sample;
        input [7:0] m, lt;
        begin
            @(negedge clk);
            moisture=m;
            leaf_temp=lt;
            sample_valid=1;
            @(negedge clk);
            sample_valid=0;
            repeat (14) @(negedge clk);
        end
    endtask

    task wake_system;
        begin
            @(negedge clk);
            wake_timer=1;
            @(negedge clk);
            wake_timer=0;
            repeat (4) @(negedge clk);
        end
    endtask

    task configure_base;
        begin
            write_register(8'h10,8'd64);
            write_register(8'h52,8'd1);
            write_register(8'h51,8'd4);
            for (i=8'h20; i<=8'h24; i=i+1)
                write_register(i,8'd0);
        end
    endtask

    task configure_tree;
        begin
            write_register(8'h60,8'd100);
            write_register(8'h62,8'hFF);
            write_register(8'h65,8'd100);
            write_register(8'h63,8'd50);
        end
    endtask

    always @(ipm_state) begin
        if (measuring && ipm_state !== expected_state) begin
            $display("FAIL unexpected state transition at %0t", $time);
            $fatal(1, "State changed during measurement");
        end
    end

    initial begin
        state_arg="";
        vcd_path="";

        if (!$value$plusargs("STATE=%s",state_arg))
            $fatal(1,"Missing STATE argument");

        if (!$value$plusargs("VCD=%s",vcd_path))
            $fatal(1,"Missing VCD argument");

        if (state_arg=="SLEEP")
            expected_state=SLEEP;
        else if (state_arg=="MONITOR")
            expected_state=MONITOR;
        else if (state_arg=="WARNING")
            expected_state=WARNING;
        else if (state_arg=="CRITICAL")
            expected_state=CRITICAL;
        else
            $fatal(1,"Invalid state");

        $display("STATE=%0s",state_arg);

        repeat (5) @(negedge clk);
        rst_n=1;
        repeat (4) @(negedge clk);
        check_state(SLEEP);

        if (expected_state!=SLEEP) begin
            wake_system;
            check_state(MONITOR);
            configure_base;
        end


        // Reproduce the original verified workload sequence.
        if (expected_state==WARNING ||
            expected_state==CRITICAL) begin

            send_sample(8'd20,8'd60);
            send_sample(8'd20,8'd60);
            send_sample(8'd120,8'd60);

            configure_tree;

            send_sample(8'd20,8'd60);
            send_sample(8'd20,8'd60);
            send_sample(8'd150,8'd60);

            check_state(CRITICAL);

            if (expected_state==WARNING) begin
                send_sample(8'd60,8'd60);
                check_state(WARNING);
            end
        end

        check_state(expected_state);

        $dumpfile(vcd_path);
        $dumpvars(0,tb_power_state);

        // Settle for 200 cycles without recording activity.
        $dumpoff;
        repeat (200) @(negedge clk);
        check_state(expected_state);

        // Record exactly 1,000 cycles.
        measuring=1;
        $display("MEASUREMENT_START %0s %0t",state_arg,$time);
        $dumpon;

        repeat (1000) @(negedge clk);

        measuring=0;
        check_state(expected_state);

        $display("MEASUREMENT_END %0s %0t",state_arg,$time);
        $display("PASS STATE=%0s",state_arg);
        $finish;
    end
endmodule
