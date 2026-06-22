// =============================================================================
// uart_tx.v — UART Transmitter
// Frame: 1 Start + 8 Data (LSB first) + 1 Parity (optional) + 1 Stop
// parity_sel: 00=None 01=Even 10=Odd
// =============================================================================
module uart_tx (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        baud_tick,
    input  wire [1:0]  parity_sel,
    input  wire        tx_start,
    input  wire [7:0]  tx_data,
    output reg         tx_serial,
    output reg         tx_busy,
    output reg         tx_done
);
    localparam IDLE   = 3'd0;
    localparam START  = 3'd1;
    localparam DATA   = 3'd2;
    localparam PARITY = 3'd3;
    localparam STOP   = 3'd4;

    reg [2:0] state;
    reg [7:0] shift_reg;
    reg [2:0] bit_cnt;
    reg       parity_bit;

    wire even_parity = ^tx_data;
    wire odd_parity  = ~(^tx_data);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= IDLE;
            tx_serial  <= 1'b1;
            tx_busy    <= 1'b0;
            tx_done    <= 1'b0;
            shift_reg  <= 8'd0;
            bit_cnt    <= 3'd0;
            parity_bit <= 1'b0;
        end else begin
            tx_done <= 1'b0;
            case (state)
                IDLE: begin
                    tx_serial <= 1'b1;
                    tx_busy   <= 1'b0;
                    if (tx_start) begin
                        shift_reg <= tx_data;
                        case (parity_sel)
                            2'b01:   parity_bit <= even_parity;
                            2'b10:   parity_bit <= odd_parity;
                            default: parity_bit <= 1'b0;
                        endcase
                        tx_busy <= 1'b1;
                        state   <= START;
                    end
                end
                START: begin
                    if (baud_tick) begin
                        tx_serial <= 1'b0;
                        bit_cnt   <= 3'd0;
                        state     <= DATA;
                    end
                end
                DATA: begin
                    if (baud_tick) begin
                        tx_serial <= shift_reg[0];
                        shift_reg <= {1'b0, shift_reg[7:1]};
                        if (bit_cnt == 3'd7) begin
                            bit_cnt <= 3'd0;
                            state   <= (parity_sel == 2'b00) ? STOP : PARITY;
                        end else
                            bit_cnt <= bit_cnt + 3'd1;
                    end
                end
                PARITY: begin
                    if (baud_tick) begin
                        tx_serial <= parity_bit;
                        state     <= STOP;
                    end
                end
                STOP: begin
                    if (baud_tick) begin
                        tx_serial <= 1'b1;
                        tx_done   <= 1'b1;
                        tx_busy   <= 1'b0;
                        state     <= IDLE;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
