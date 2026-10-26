// Serialized Crop Stress Accelerator: one shared 8x8 multiplier.
//
// stress_score = min(255, (sum_i s_i * w_i) >> shift_factor), i = 0..4
//
// Timing (edge S = clock edge at which a start is sampled):
//   S       : accumulator cleared, lane index 0, busy=1, score_valid=0
//   S+1..S+5: lane i = 0..4 product accumulated
//   S+5     : stress_score loaded (normalized), score_valid=1, busy=0
// The new score is observable in the cycle after edge S+5 (latency 5 edges).
//
// Operands (sensors, weights, shift) are read live during S+1..S+5; they must
// be stable for the computation. Restart rules guarantee that each result
// uses one coherent operand set:
//   start   = sample_valid | (cfg_write & busy)  -> (re)starts at index 0
//   enable=0 aborts: busy=0, score_valid=0 (highest priority)
// A restart on the final edge wins over completion. An idle cfg_write does not
// recompute (score keeps reflecting the configuration at its computation).
// stress_score holds its previous value until the next completion.
// Accumulator: 5 * 255 * 255 = 325,125 < 2^19.

module crop_stress_accelerator(
    input wire        clk,
    input wire        rst_n,
    input wire        enable,
    input wire        sample_valid,
    input wire        cfg_write,
    input wire [7:0]  moisture,
    input wire [7:0]  leaf_temp,
    input wire [7:0]  humidity,
    input wire [7:0]  air_temp,
    input wire [7:0]  light,

    input wire [7:0]  w_moisture,
    input wire [7:0]  w_leaftemp,
    input wire [7:0]  w_humidity,
    input wire [7:0]  w_airtemp,
    input wire [7:0]  w_light,

    input wire [3:0]  shift_factor,

    output reg  [7:0] stress_score,
    output reg        score_valid,
    output reg        busy
);

    reg [2:0]  lane;
    reg [18:0] acc;

    reg [7:0] s_op;
    reg [7:0] w_op;
    always @(*) begin
        case (lane)
            3'd0:    begin s_op = moisture;  w_op = w_moisture; end
            3'd1:    begin s_op = leaf_temp; w_op = w_leaftemp; end
            3'd2:    begin s_op = humidity;  w_op = w_humidity; end
            3'd3:    begin s_op = air_temp;  w_op = w_airtemp;  end
            default: begin s_op = light;     w_op = w_light;    end
        endcase
    end

    wire [15:0] product;
    weighted_sum ws_shared (
        .sensor_value(s_op),
        .weight(w_op),
        .product(product)
    );

    wire [18:0] acc_next = acc + {3'b000, product};

    wire [7:0] score_next;
    normalization_unit norm_inst (
        .weighted_sum_val(acc_next),
        .shift_factor(shift_factor),
        .stress_score(score_next)
    );

    wire start = sample_valid | (cfg_write & busy);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lane         <= 3'd0;
            acc          <= 19'd0;
            busy         <= 1'b0;
            score_valid  <= 1'b0;
            stress_score <= 8'd0;
        end else if (!enable) begin
            busy        <= 1'b0;
            score_valid <= 1'b0;
            lane        <= 3'd0;
        end else if (start) begin
            lane        <= 3'd0;
            acc         <= 19'd0;
            busy        <= 1'b1;
            score_valid <= 1'b0;
        end else if (busy) begin
            if (lane == 3'd4) begin
                stress_score <= score_next;
                score_valid  <= 1'b1;
                busy         <= 1'b0;
                lane         <= 3'd0;
            end else begin
                acc  <= acc_next;
                lane <= lane + 3'd1;
            end
        end
    end

endmodule
