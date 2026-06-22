// =============================================================================
// uart_controller.v — Top-Level UART Controller
// =============================================================================
module uart_controller (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [2:0]  baud_sel,
    input  wire [1:0]  parity_sel,
    input  wire        tx_start,
    input  wire [7:0]  tx_data,
    output wire        tx_serial,
    output wire        tx_busy,
    output wire        tx_done,
    input  wire        rx_serial,
    output wire [7:0]  rx_data,
    output wire        rx_done,
    output wire        parity_error,
    output wire        framing_error
);
    wire baud_tick;

    baud_gen u_baud_gen (
        .clk       (clk),
        .rst_n     (rst_n),
        .baud_sel  (baud_sel),
        .baud_tick (baud_tick)
    );
    uart_tx u_uart_tx (
        .clk        (clk),
        .rst_n      (rst_n),
        .baud_tick  (baud_tick),
        .parity_sel (parity_sel),
        .tx_start   (tx_start),
        .tx_data    (tx_data),
        .tx_serial  (tx_serial),
        .tx_busy    (tx_busy),
        .tx_done    (tx_done)
    );
    uart_rx u_uart_rx (
        .clk          (clk),
        .rst_n        (rst_n),
        .baud_tick    (baud_tick),
        .parity_sel   (parity_sel),
        .rx_serial    (rx_serial),
        .rx_data      (rx_data),
        .rx_done      (rx_done),
        .parity_error (parity_error),
        .framing_error(framing_error)
    );
endmodule
