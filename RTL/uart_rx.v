// =============================================================================
// uart_rx.v — UART Receiver with Parity & Framing Error Detection
// parity_sel: 00=None 01=Even 10=Odd
//
// parity_error and framing_error are held stable from STOP_CHECK until the
// next frame's START_DETECT so the testbench can read them after rx_done.
// =============================================================================
module uart_rx (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        baud_tick,
    input  wire [1:0]  parity_sel,
    input  wire        rx_serial,
    output reg  [7:0]  rx_data,
    output reg         rx_done,
    output reg         parity_error,
    output reg         framing_error
);
    localparam IDLE         = 3'd0;
    localparam START_DETECT = 3'd1;
    localparam DATA_RECEIVE = 3'd2;
    localparam PARITY_CHECK = 3'd3;
    localparam STOP_CHECK   = 3'd4;

    reg [2:0] state;
    reg [7:0] shift_reg;
    reg [2:0] bit_cnt;
    reg       rx_parity_calc;
    reg       rx_parity_rcvd;

    reg rx_s1, rx_s2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rx_s1 <= 1'b1; rx_s2 <= 1'b1; end
        else        begin rx_s1 <= rx_serial; rx_s2 <= rx_s1; end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= IDLE;
            shift_reg      <= 8'd0;
            bit_cnt        <= 3'd0;
            rx_data        <= 8'd0;
            rx_done        <= 1'b0;
            parity_error   <= 1'b0;
            framing_error  <= 1'b0;
            rx_parity_calc <= 1'b0;
            rx_parity_rcvd <= 1'b0;
        end else begin
            rx_done <= 1'b0;
            // parity_error and framing_error intentionally have no default here;
            // they are set in STOP_CHECK and cleared in START_DETECT.
            case (state)
                IDLE: begin
                    if (!rx_s2) state <= START_DETECT;
                end
                START_DETECT: begin
                    parity_error  <= 1'b0;
                    framing_error <= 1'b0;
                    if (baud_tick) begin
                        if (!rx_s2) begin
                            rx_parity_calc <= 1'b0;
                            bit_cnt        <= 3'd0;
                            state          <= DATA_RECEIVE;
                        end else
                            state <= IDLE;
                    end
                end
                DATA_RECEIVE: begin
                    if (baud_tick) begin
                        shift_reg      <= {rx_s2, shift_reg[7:1]};
                        rx_parity_calc <= rx_parity_calc ^ rx_s2;
                        if (bit_cnt == 3'd7) begin
                            bit_cnt <= 3'd0;
                            state   <= (parity_sel == 2'b00) ? STOP_CHECK : PARITY_CHECK;
                        end else
                            bit_cnt <= bit_cnt + 3'd1;
                    end
                end
                PARITY_CHECK: begin
                    if (baud_tick) begin
                        rx_parity_rcvd <= rx_s2;
                        state          <= STOP_CHECK;
                    end
                end
                STOP_CHECK: begin
                    if (baud_tick) begin
                        rx_data <= shift_reg;
                        rx_done <= 1'b1;
                        framing_error <= !rx_s2;
                        if (parity_sel != 2'b00) begin
                            if (parity_sel == 2'b01)
                                parity_error <= (rx_parity_calc != rx_parity_rcvd);
                            else
                                parity_error <= (rx_parity_calc == rx_parity_rcvd);
                        end else
                            parity_error <= 1'b0;
                        state <= IDLE;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
