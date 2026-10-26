// synthesis-clean: no `timescale in RTL
`include "agrisense_defs.vh"

module agrisense_ipms_top(
    input  wire       clk,
    input  wire       rst_n,

    // SPI / Register Bus interface (Master)
    input  wire [7:0] m_addr,
    input  wire [7:0] m_wdata,
    input  wire       m_we,
    input  wire       m_re,
    output wire [7:0] m_rdata,

    // Sensor Interfaces (stubbed as simple direct inputs for now)
    input  wire       sample_valid,
    input  wire [7:0] moisture,
    input  wire [7:0] leaf_temp,
    input  wire [7:0] humidity,
    input  wire [7:0] air_temp,
    input  wire [7:0] light,
    input  wire [7:0] battery,

    // Timers
    input  wire       wake_timer,

    // Status / Outputs
    output wire [3:0] leaf_output,
    output wire [1:0] ipm_state,
    output wire       domain2_pwr_en,
    output wire       domain3_pwr_en,
    output wire       comm_en_out,
    output wire [9:0] adc_mode_vector
);

    // ==========================================
    // 0. INPUT SYNCHRONIZATION
    // ==========================================
    
    wire wake_timer_sync;
    wire sample_valid_sync;

    wake_controller u_wake_sync (
        .clk(clk),
        .rst_n(rst_n),
        .wake_timer_raw(wake_timer),
        .sample_valid_raw(sample_valid),
        .wake_timer_sync(wake_timer_sync),
        .sample_valid_sync(sample_valid_sync)
    );

    wire [47:0] sensor_bundle_sync;
    sample_bus_pipeline #(.WIDTH(48)) u_sensor_sample_pipe (
        .clk(clk),
        .rst_n(rst_n),
        .sample_in({battery, light, air_temp, humidity, leaf_temp, moisture}),
        .sample_out(sensor_bundle_sync)
    );

    wire [7:0] moisture_sample = sensor_bundle_sync[7:0];
    wire [7:0] leaf_temp_sample = sensor_bundle_sync[15:8];
    wire [7:0] humidity_sample = sensor_bundle_sync[23:16];
    wire [7:0] air_temp_sample = sensor_bundle_sync[31:24];
    wire [7:0] light_sample = sensor_bundle_sync[39:32];
    wire [7:0] battery_sample = sensor_bundle_sync[47:40];

    // ==========================================
    // 1. REGISTER BUS & REGISTER FILE (DOMAIN 1)
    // ==========================================
    
    wire [7:0] w_moisture;
    wire [7:0] w_leaftemp;
    wire [7:0] w_humidity;
    wire [7:0] w_airtemp;
    wire [7:0] w_light;

    wire [2:0] sf_0, sf_1, sf_2, sf_3, sf_4;
    wire [2:0] vote_threshold;
    wire [7:0] window_size;

    wire [7:0] t0, t1, t2, t3, t4, t5, t6;

    wire [7:0] moisture_t1, moisture_t2;
    wire [7:0] leaf_t1, leaf_t2;
    wire [7:0] humidity_t1, humidity_t2;
    wire [7:0] air_t1, air_t2;
    wire [7:0] light_t1, light_t2;
    wire [7:0] b_crit, b_low;

    wire [7:0] adc_mode_lsb;
    wire [1:0] adc_mode_msb;
    wire [3:0] normalization_shift;
    wire [9:0] fusion_pattern;
    /* verilator lint_off UNUSEDSIGNAL */
    wire       weights_valid;
    /* verilator lint_on UNUSEDSIGNAL */

    wire [7:0] stress_score_iso;
    wire [3:0] leaf_output_iso;
    wire [4:0] cross_flag_vector;
    wire [2:0] fusion_score;
    wire       stress_event;
    
    wire sensor_en;
    wire csa_en;
    wire decde_en;
    wire dtree_en;

    wire csa_score_valid;
    wire leaf_valid = dtree_en & csa_score_valid;

    wire sample_accept = sample_valid_sync & sensor_en;
    reg sample_available;
    reg [7:0] sampled_moisture;
    reg [7:0] sampled_leaf_temp;
    reg [7:0] sampled_humidity;
    reg [7:0] sampled_air_temp;
    reg [7:0] sampled_light;
    reg [7:0] sampled_battery;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_available <= 1'b0;
            sampled_moisture <= 8'd0;
            sampled_leaf_temp <= 8'd0;
            sampled_humidity <= 8'd0;
            sampled_air_temp <= 8'd0;
            sampled_light <= 8'd0;
            sampled_battery <= 8'd0;
        end else if (sample_accept) begin
            sample_available <= 1'b1;
            sampled_moisture <= moisture_sample;
            sampled_leaf_temp <= leaf_temp_sample;
            sampled_humidity <= humidity_sample;
            sampled_air_temp <= air_temp_sample;
            sampled_light <= light_sample;
            sampled_battery <= battery_sample;
        end
    end
    
    register_file u_reg_file (
        .clk(clk),
        .rst_n(rst_n),
        .addr(m_addr),
        .wdata(m_wdata),
        .we(m_we),
        .re(m_re),
        .rdata(m_rdata),
        
        .w_moisture(w_moisture),
        .w_leaftemp(w_leaftemp),
        .w_humidity(w_humidity),
        .w_airtemp(w_airtemp),
        .w_light(w_light),

        .shift_factor_0(sf_0),
        .shift_factor_1(sf_1),
        .shift_factor_2(sf_2),
        .shift_factor_3(sf_3),
        .shift_factor_4(sf_4),

        .vote_threshold(vote_threshold),
        .window_size(window_size),
        .normalization_shift(normalization_shift),
        .fusion_pattern(fusion_pattern),
        .weights_valid(weights_valid),

        .t0(t0), .t1(t1), .t2(t2), .t3(t3), .t4(t4), .t5(t5), .t6(t6),

        .moisture_t1(moisture_t1), .moisture_t2(moisture_t2),
        .leaf_t1(leaf_t1), .leaf_t2(leaf_t2),
        .humidity_t1(humidity_t1), .humidity_t2(humidity_t2),
        .air_t1(air_t1), .air_t2(air_t2),
        .light_t1(light_t1), .light_t2(light_t2),
        .b_crit(b_crit), .b_low(b_low),

        // Status Inputs
        .status_moisture(sampled_moisture),
        .status_leaftemp(sampled_leaf_temp),
        .status_humidity(sampled_humidity),
        .status_airtemp(sampled_air_temp),
        .status_light(sampled_light),
        .status_battery(sampled_battery),
        
        .status_stress_score(stress_score_iso),
        .status_cross_flags(cross_flag_vector),
        .status_fusion_score(fusion_score),
        .status_stress_event(stress_event),
        .status_leaf_output(leaf_output_iso),
        
        .status_adc_mode_lsb(adc_mode_lsb),
        .status_adc_mode_msb(adc_mode_msb),
        
        .status_ipm_state(ipm_state),
        .status_ipm_enables({1'b0, domain3_pwr_en, domain2_pwr_en, comm_en_out, dtree_en, csa_en, decde_en, sensor_en})
    );

    // ==========================================
    // 2. IPM FSM
    // ==========================================
    
    ipm_fsm u_ipm (
        .clk(clk),
        .rst_n(rst_n),
        .wake_timer(wake_timer_sync),
        .stress_event(stress_event),
        .leaf_output(leaf_output_iso),
        .leaf_valid(leaf_valid),
        .state(ipm_state),
        .domain2_pwr_en(domain2_pwr_en),
        .domain3_pwr_en(domain3_pwr_en),
        .sensor_en(sensor_en),
        .decde_en(decde_en),
        .csa_en(csa_en),
        .dtree_en(dtree_en),
        .comm_en(comm_en_out)
    );

    // ==========================================
    // 3. STRESS-AWARE ADC CONTROLLER (SA-ADC)
    // ==========================================

    /* verilator lint_off UNUSEDSIGNAL */
    wire adc_mode_valid; // not exported at top: adc_mode_vector holds last mode
    /* verilator lint_on UNUSEDSIGNAL */
    sa_adc_controller u_sa_adc (
        .clk(clk),
        .rst_n(rst_n),
        .sample_valid(sample_accept),
        .moisture(moisture_sample),
        .leaf_temp(leaf_temp_sample),
        .humidity(humidity_sample),
        .air_temp(air_temp_sample),
        .light(light_sample),
        .fusion_score(fusion_score),
        .battery_level(battery_sample),
        
        .moisture_t1(moisture_t1), .moisture_t2(moisture_t2),
        .leaf_t1(leaf_t1), .leaf_t2(leaf_t2),
        .humidity_t1(humidity_t1), .humidity_t2(humidity_t2),
        .air_t1(air_t1), .air_t2(air_t2),
        .light_t1(light_t1), .light_t2(light_t2),
        .b_crit(b_crit), .b_low(b_low),
        
        .adc_mode_vector(adc_mode_vector),
        .mode_valid(adc_mode_valid)
    );

    assign adc_mode_lsb = adc_mode_vector[7:0];
    assign adc_mode_msb = adc_mode_vector[9:8];

    // ==========================================
    // 4. DECDE CHANNELS x5
    // ==========================================
    
    // Gating sample valid with IPM's decde_en
    wire gated_sample_valid = sample_accept & decde_en;

    wire cross_0, cross_1, cross_2, cross_3, cross_4;
    wire trend_0, trend_1, trend_2, trend_3, trend_4;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [2:0] sid_0, sid_1, sid_2, sid_3, sid_4;
    /* verilator lint_on UNUSEDSIGNAL */

    decde_channel #(.SENSOR_ID(0)) u_decde_0(
        .clk(clk), .rst_n(rst_n),
        .sample_valid(gated_sample_valid), .sensor_sample(moisture_sample), .shift_factor(sf_0),
        .cross_flag(cross_0), .trend_direction(trend_0), .sensor_id_out(sid_0)
    );

    decde_channel #(.SENSOR_ID(1)) u_decde_1(
        .clk(clk), .rst_n(rst_n),
        .sample_valid(gated_sample_valid), .sensor_sample(leaf_temp_sample), .shift_factor(sf_1),
        .cross_flag(cross_1), .trend_direction(trend_1), .sensor_id_out(sid_1)
    );

    decde_channel #(.SENSOR_ID(2)) u_decde_2(
        .clk(clk), .rst_n(rst_n),
        .sample_valid(gated_sample_valid), .sensor_sample(humidity_sample), .shift_factor(sf_2),
        .cross_flag(cross_2), .trend_direction(trend_2), .sensor_id_out(sid_2)
    );

    decde_channel #(.SENSOR_ID(3)) u_decde_3(
        .clk(clk), .rst_n(rst_n),
        .sample_valid(gated_sample_valid), .sensor_sample(air_temp_sample), .shift_factor(sf_3),
        .cross_flag(cross_3), .trend_direction(trend_3), .sensor_id_out(sid_3)
    );

    decde_channel #(.SENSOR_ID(4)) u_decde_4(
        .clk(clk), .rst_n(rst_n),
        .sample_valid(gated_sample_valid), .sensor_sample(light_sample), .shift_factor(sf_4),
        .cross_flag(cross_4), .trend_direction(trend_4), .sensor_id_out(sid_4)
    );

    // ==========================================
    // 5. FUSION UNIT
    // ==========================================

    assign cross_flag_vector = {cross_4, cross_3, cross_2, cross_1, cross_0};
    wire [4:0] trend_direction_vector = {trend_4, trend_3, trend_2, trend_1, trend_0};

    fusion_unit u_fusion (
        .clk(clk),
        .rst_n(rst_n),
        .cross_flag_vector(cross_flag_vector),
        .trend_direction_vector(trend_direction_vector),
        .fusion_pattern(fusion_pattern),
        .vote_threshold(vote_threshold),
        .window_size(window_size),
        .fusion_score(fusion_score),
        .stress_event(stress_event)
    );

    // ==========================================
    // 6. CROP STRESS ACCELERATOR (CSA)
    // ==========================================

    wire [7:0] stress_score_raw;
    // Serialized CSA: operands are the held tuple sampled_*, which updates on the
    // same edge a sample is accepted, so a start on that edge reads the new
    // tuple from the next edge on. A held sample is also (re)scored when Domain 2
    // turns on with no valid score. Weight/shift writes restart a busy CSA.
    wire csa_busy;
    wire csa_capture = domain2_pwr_en &&
                       (sample_accept || (sample_available && !csa_score_valid && !csa_busy));
    wire csa_cfg_write = m_we && ((m_addr >= 8'h10 && m_addr <= 8'h14) || m_addr == 8'h19);
    crop_stress_accelerator u_csa (
        .clk(clk),
        .rst_n(rst_n),
        .enable(domain2_pwr_en),
        .sample_valid(csa_capture),
        .cfg_write(csa_cfg_write),
        .moisture(sampled_moisture),
        .leaf_temp(sampled_leaf_temp),
        .humidity(sampled_humidity),
        .air_temp(sampled_air_temp),
        .light(sampled_light),
        
        .w_moisture(w_moisture),
        .w_leaftemp(w_leaftemp),
        .w_humidity(w_humidity),
        .w_airtemp(w_airtemp),
        .w_light(w_light),
        
        .shift_factor(normalization_shift),
        
        .stress_score(stress_score_raw),
        .score_valid(csa_score_valid),
        .busy(csa_busy)
    );

    // ==========================================
    // 7. DECISION TREE ACCELERATOR
    // ==========================================

    wire [3:0] leaf_output_raw;

    decision_tree_accelerator u_dt (
        .moisture(sampled_moisture),
        .leaf_temp(sampled_leaf_temp),
        .humidity(sampled_humidity),
        .air_temp(sampled_air_temp),
        .light(sampled_light),
        
        .stress_score(stress_score_raw),
        .fusion_score(fusion_score),
        
        .stress_event(leaf_valid),
        
        .t0(t0), .t1(t1), .t2(t2), .t3(t3), .t4(t4), .t5(t5), .t6(t6),
        
        .leaf_output(leaf_output_raw)
    );

    // ==========================================
    // 8. POWER CONTROLLER (BOUNDARY ISOLATION)
    // ==========================================

    power_controller u_pwr_ctrl (
        .stress_score_in(stress_score_raw),
        .leaf_output_in(leaf_output_raw),
        .domain2_pwr_en(domain2_pwr_en),
        .stress_score_iso(stress_score_iso),
        .leaf_output_iso(leaf_output_iso)
    );

    assign leaf_output = leaf_output_iso;

endmodule
