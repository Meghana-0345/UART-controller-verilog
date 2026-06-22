// =============================================================================
// baud_gen.v — Configurable Baud Rate Generator  (50 MHz system clock)
// baud_sel: 000=9600 001=19200 010=38400 011=57600 100=115200
// =============================================================================
module baud_gen (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [2:0]  baud_sel,
    output reg         baud_tick
);
    reg [12:0] divisor;
    reg [12:0] counter;

    always @(*) begin
        case (baud_sel)
            3'b000: divisor = 13'd5208;
            3'b001: divisor = 13'd2604;
            3'b010: divisor = 13'd1302;
            3'b011: divisor = 13'd868;
            3'b100: divisor = 13'd434;
            default: divisor = 13'd5208;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            counter   <= 13'd1;
            baud_tick <= 1'b0;
        end else begin
            if (counter == 13'd1) begin
                counter   <= divisor;
                baud_tick <= 1'b1;
            end else begin
                counter   <= counter - 13'd1;
                baud_tick <= 1'b0;
            end
        end
    end
endmodule
