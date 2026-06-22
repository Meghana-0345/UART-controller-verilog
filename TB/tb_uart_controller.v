// =============================================================================
// tb_uart_controller.v — ModelSim-Altera Testbench with Scoreboard
//
// TC6 FIX HISTORY:
//
// Attempt 1 (bit_period_ns exact multiples + 2*bp corrupt stop hold):
//   Fixed frame-level timing drift. Correctly set framing_error (confirmed
//   by attempt-2's atomic capture), BUT holding rx_serial low for a full
//   extra bit period meant that once STOP_CHECK combinationally dropped to
//   IDLE, the still-low line was immediately re-interpreted as a new start
//   bit. That phantom frame free-ran for ~10 bit periods sampling whatever
//   was actually on the wire -- including the tail of the idle gap and the
//   START of the next real frame -- producing corrupted data on the
//   FOLLOWING call (e.g. rx_data=0xF7 instead of 0xFF) even though the
//   error-detection test itself passed.
//
// Attempt 2 (capture parity_error/framing_error atomically with rx_done):
//   Fixed the read race (flags being cleared by START_DETECT before the
//   testbench got around to checking them). Necessary, but insufficient on
//   its own -- it didn't address the phantom-restart corrupting the NEXT
//   frame's data.
//
// Attempt 3 (this version) — root cause is the UNKNOWN baud_tick phase:
//   baud_gen free-runs and is never reset per-frame, so without
//   synchronization the RTL's sample point inside any bit window can land
//   anywhere from 0 to a full bit period (bp) after the window opens. That
//   forces the corrupt-stop hold to last almost a full extra bp to cover
//   the worst case -- which is also long enough to still be low when IDLE
//   re-checks the line, causing the phantom restart described above.
//
//   Fix: synchronize the frame's start-bit transition to the DUT's
//   free-running baud_tick (via hierarchical reference). This pins the
//   RTL's sample point to a small, FIXED, known offset (SYNC_MARGIN) after
//   each bit window opens, instead of an unbounded value up to a full bp.
//   With a known offset, the corrupt stop bit only needs to be held low
//   for ~2*SYNC_MARGIN (comfortably covering the sample point) and can
//   return high for the remainder of that SAME bit slot -- long before the
//   next baud_tick arrives. Any momentary glimpse into START_DETECT is now
//   harmless: by the time the confirming tick arrives a full bp later, the
//   line is already high, so the FSM reverts to IDLE instead of free-
//   running into DATA_RECEIVE.
// =============================================================================

`timescale 1ns/1ps

module tb_uart_controller;

    parameter CLK_PERIOD  = 20;            // 50 MHz
    parameter SYNC_MARGIN = 10 * CLK_PERIOD; // 200 ns: small, fixed phase margin

    reg        clk;
    reg        rst_n;
    reg  [2:0] baud_sel;
    reg  [1:0] parity_sel;
    reg        tx_start;
    reg  [7:0] tx_data;
    wire       tx_serial;
    wire       tx_busy;
    wire       tx_done;
    reg        rx_serial;
    wire [7:0] rx_data;
    wire       rx_done;
    wire       parity_error;
    wire       framing_error;

    integer pass_count;
    integer fail_count;

    // Captured copies of parity_error/framing_error, sampled atomically with
    // rx_done inside wait_rx_done(). All checks use these, never the live
    // DUT wires, to avoid the post-rx_done clear race (see Attempt 2 above).
    reg pe_cap;
    reg fe_cap;

    task report_pass;
        input [255:0] test_name;
        begin
            $display("[PASS] %0t | %s", $time, test_name);
            pass_count = pass_count + 1;
        end
    endtask

    task report_fail;
        input [255:0] test_name;
        input [255:0] reason;
        begin
            $display("[FAIL] %0t | %s | %s", $time, test_name, reason);
            fail_count = fail_count + 1;
        end
    endtask

    uart_controller DUT (
        .clk           (clk),
        .rst_n         (rst_n),
        .baud_sel      (baud_sel),
        .parity_sel    (parity_sel),
        .tx_start      (tx_start),
        .tx_data       (tx_data),
        .tx_serial     (tx_serial),
        .tx_busy       (tx_busy),
        .tx_done       (tx_done),
        .rx_serial     (rx_serial),
        .rx_data       (rx_data),
        .rx_done       (rx_done),
        .parity_error  (parity_error),
        .framing_error (framing_error)
    );

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // bit_period_ns: exact divisor*CLK_PERIOD values (matches baud_gen exactly,
    // eliminates frame-level phase drift).
    // -------------------------------------------------------------------------
    function integer bit_period_ns;
        input [2:0] sel;
        begin
            case (sel)
                3'b000: bit_period_ns = 104160; // 5208 * 20
                3'b001: bit_period_ns =  52080; // 2604 * 20
                3'b010: bit_period_ns =  26040; // 1302 * 20
                3'b011: bit_period_ns =  17360; //  868 * 20
                3'b100: bit_period_ns =   8680; //  434 * 20
                default: bit_period_ns = 104160;
            endcase
        end
    endfunction

    task send_tx_byte;
        input [7:0] data;
        begin
            @(posedge clk);
            tx_data  = data;
            tx_start = 1'b1;
            @(posedge clk);
            tx_start = 1'b0;
            @(posedge tx_done);
            @(posedge clk);
        end
    endtask

    // -------------------------------------------------------------------------
    // drive_rx_frame
    //
    // Synchronizes the start-bit transition to the DUT's free-running
    // baud_tick (DUT.u_baud_gen.baud_tick) so the RTL's sample point inside
    // every bit window falls at a small, FIXED offset (~SYNC_MARGIN) after
    // the window opens, instead of an unknown phase anywhere within a full
    // bit period. This is what lets the corrupt-stop hold stay short (see
    // below) instead of needing a full extra bit period.
    //
    // Corrupt stop bit: held low for only 2*SYNC_MARGIN -- comfortably more
    // than SYNC_MARGIN plus the 2-stage input synchronizer's ~2*CLK_PERIOD
    // delay -- then returns high for the REMAINDER of that same bit slot.
    // Total stop-bit slot duration stays exactly bp, same as every other
    // bit, so there's no extended low pulse left over to be misread as a
    // new start condition once STOP_CHECK returns to IDLE.
    // -------------------------------------------------------------------------
    task drive_rx_frame;
        input [7:0]  data;
        input [1:0]  par_sel;
        input        parity_corrupt;
        input        stop_corrupt;
        integer      bp;
        reg          par_bit;
        integer      i;
        begin
            bp = bit_period_ns(baud_sel);

            case (par_sel)
                2'b01:   par_bit = ^data;
                2'b10:   par_bit = ~(^data);
                default: par_bit = 1'b0;
            endcase
            if (parity_corrupt) par_bit = ~par_bit;

            // Sync: wait for a baud_tick, then wait until just before the
            // NEXT tick (bp - SYNC_MARGIN later) before driving the start
            // bit. This makes the FIRST confirm-tick land ~SYNC_MARGIN
            // after our start-bit transition, and -- since baud_tick free-
            // runs at an exact bp cadence thereafter -- every subsequent
            // sample point lands ~SYNC_MARGIN after each of our bit windows
            // opens, for the rest of this frame.
            @(posedge DUT.u_baud_gen.baud_tick);
            #(bp - SYNC_MARGIN);

            // Start bit
            rx_serial = 1'b0;
            #(bp);

            // Data bits LSB first
            for (i = 0; i < 8; i = i + 1) begin
                rx_serial = data[i];
                #(bp);
            end

            // Parity bit
            if (par_sel != 2'b00) begin
                rx_serial = par_bit;
                #(bp);
            end

            // Stop bit
            if (stop_corrupt) begin
                rx_serial = 1'b0;
                #(2 * SYNC_MARGIN);              // covers the known sample point
                rx_serial = 1'b1;
                #(bp - 2 * SYNC_MARGIN);          // back to idle well within this bit slot
            end else begin
                rx_serial = 1'b1;
                #(bp);
            end

            // Return to idle
            rx_serial = 1'b1;
            #(bp);
        end
    endtask

    // -------------------------------------------------------------------------
    // wait_rx_done — samples parity_error/framing_error in the SAME
    // #(CLK_PERIOD) step where rx_done is observed asserted, capturing them
    // atomically. Avoids the race where a (real or phantom) START_DETECT
    // clears the flags before the caller checks them after fork/join.
    // -------------------------------------------------------------------------
    task wait_rx_done;
        input  integer timeout_ns;
        output         got_it;
        output         pe_captured;
        output         fe_captured;
        integer        t;
        begin
            got_it      = 0;
            pe_captured = 1'b0;
            fe_captured = 1'b0;
            t = 0;
            while (t < timeout_ns && !rx_done) begin
                #(CLK_PERIOD);
                t = t + CLK_PERIOD;
            end
            if (rx_done) begin
                got_it      = 1;
                pe_captured = parity_error;   // captured same instant as rx_done
                fe_captured = framing_error;  // captured same instant as rx_done
            end
        end
    endtask

    integer i;
    integer got_rx;
    integer timeout;

    initial begin
        pass_count = 0;
        fail_count = 0;
        rst_n      = 1'b0;
        baud_sel   = 3'b100;
        parity_sel = 2'b00;
        tx_start   = 1'b0;
        tx_data    = 8'd0;
        rx_serial  = 1'b1;

        // =====================================================================
        // TC1 — Reset
        // =====================================================================
        $display("\n--- TC1: Reset Behavior ---");
        repeat(4) @(posedge clk);
        rst_n = 1'b1;
        repeat(4) @(posedge clk);

        if (tx_busy === 1'b0 && tx_serial === 1'b1)
            report_pass("TC1_RESET_TX_IDLE");
        else
            report_fail("TC1_RESET_TX_IDLE", "TX not idle after reset");

        // =====================================================================
        // TC2 — Single byte TX 0x55
        // =====================================================================
        $display("\n--- TC2: TX 0x55 (8-N-1, 115200) ---");
        baud_sel   = 3'b100;
        parity_sel = 2'b00;

        @(posedge clk);
        tx_data  = 8'h55;
        tx_start = 1'b1;
        @(posedge clk);
        tx_start = 1'b0;
        @(posedge clk);   // tx_busy FF needs one extra edge to settle

        if (tx_busy !== 1'b1)
            report_fail("TC2_TX_BUSY", "tx_busy not asserted after tx_start");
        else
            report_pass("TC2_TX_BUSY");

        @(posedge tx_done);
        report_pass("TC2_TX_DONE");
        #(bit_period_ns(baud_sel) * 2);

        // =====================================================================
        // TC3 — Single byte RX 0xAA
        // =====================================================================
        $display("\n--- TC3: RX 0xAA (8-N-1, 115200) ---");
        baud_sel   = 3'b100;
        parity_sel = 2'b00;
        timeout = bit_period_ns(3'b100) * 15;
        fork
            drive_rx_frame(8'hAA, 2'b00, 0, 0);
            wait_rx_done(timeout, got_rx, pe_cap, fe_cap);
        join
        if (got_rx && rx_data === 8'hAA && !pe_cap && !fe_cap)
            report_pass("TC3_RX_DATA_MATCH");
        else begin
            $display("  rx_data=%h got_rx=%0d pe=%0b fe=%0b",
                      rx_data, got_rx, pe_cap, fe_cap);
            report_fail("TC3_RX_DATA_MATCH", "Mismatch or error flags");
        end

        // =====================================================================
        // TC4 — Baud rate switch 115200 -> 9600
        // =====================================================================
        $display("\n--- TC4: Baud Rate Switch (115200 -> 9600) ---");
        baud_sel   = 3'b100;
        parity_sel = 2'b00;
        timeout    = bit_period_ns(3'b100) * 15;
        fork
            drive_rx_frame(8'h5A, 2'b00, 0, 0);
            wait_rx_done(timeout, got_rx, pe_cap, fe_cap);
        join
        if (got_rx && rx_data === 8'h5A)
            report_pass("TC4_115200_OK");
        else
            report_fail("TC4_115200_OK", "Failed at 115200");

        baud_sel = 3'b000;
        #(bit_period_ns(3'b000) * 2);
        timeout = bit_period_ns(3'b000) * 15;
        fork
            drive_rx_frame(8'hA5, 2'b00, 0, 0);
            wait_rx_done(timeout, got_rx, pe_cap, fe_cap);
        join
        if (got_rx && rx_data === 8'hA5)
            report_pass("TC4_9600_OK");
        else
            report_fail("TC4_9600_OK", "Failed at 9600");

        baud_sel = 3'b100;

        // =====================================================================
        // TC5 — Parity error injection
        // =====================================================================
        $display("\n--- TC5: Parity Error Injection (Even parity) ---");
        baud_sel   = 3'b100;
        parity_sel = 2'b01;
        timeout = bit_period_ns(3'b100) * 15;
        fork
            drive_rx_frame(8'h55, 2'b01, 1, 0);
            wait_rx_done(timeout, got_rx, pe_cap, fe_cap);
        join
        if (got_rx && pe_cap === 1'b1 && fe_cap === 1'b0)
            report_pass("TC5_PARITY_ERROR_DETECTED");
        else begin
            $display("  pe=%0b fe=%0b got_rx=%0d", pe_cap, fe_cap, got_rx);
            report_fail("TC5_PARITY_ERROR_DETECTED", "parity_error not asserted");
        end

        #(bit_period_ns(3'b100));
        timeout = bit_period_ns(3'b100) * 15;
        fork
            drive_rx_frame(8'h55, 2'b01, 0, 0);
            wait_rx_done(timeout, got_rx, pe_cap, fe_cap);
        join
        if (got_rx && rx_data === 8'h55 && !pe_cap)
            report_pass("TC5_RECOVERY_AFTER_PARITY_ERR");
        else
            report_fail("TC5_RECOVERY_AFTER_PARITY_ERR", "RX did not recover");

        // =====================================================================
        // TC6 — Framing error injection (corrupt stop bit = 0)
        // =====================================================================
        $display("\n--- TC6: Framing Error Injection ---");
        baud_sel   = 3'b100;
        parity_sel = 2'b00;
        timeout = bit_period_ns(3'b100) * 16;
        fork
            drive_rx_frame(8'hFF, 2'b00, 0, 1);
            wait_rx_done(timeout, got_rx, pe_cap, fe_cap);
        join
        if (got_rx && fe_cap === 1'b1 && pe_cap === 1'b0)
            report_pass("TC6_FRAMING_ERROR_DETECTED");
        else begin
            $display("  pe=%0b fe=%0b got_rx=%0d", pe_cap, fe_cap, got_rx);
            report_fail("TC6_FRAMING_ERROR_DETECTED", "framing_error not asserted");
        end

        #(bit_period_ns(3'b100) * 2);
        timeout = bit_period_ns(3'b100) * 15;
        fork
            drive_rx_frame(8'hFF, 2'b00, 0, 0);
            wait_rx_done(timeout, got_rx, pe_cap, fe_cap);
        join
        if (got_rx && rx_data === 8'hFF && !fe_cap)
            report_pass("TC6_RECOVERY_AFTER_FRAMING_ERR");
        else begin
            $display("  rx_data=%h fe=%0b got_rx=%0d", rx_data, fe_cap, got_rx);
            report_fail("TC6_RECOVERY_AFTER_FRAMING_ERR", "RX did not recover");
        end

        // =====================================================================
        // TC7 — Back-to-back 20 bytes
        // =====================================================================
        $display("\n--- TC7: Back-to-back 20 bytes (8-N-1, 115200) ---");
        baud_sel   = 3'b100;
        parity_sel = 2'b00;

        begin : tc7_block
            integer bb_pass, bb_fail;
            reg [7:0] bb_data [0:19];
            reg [7:0] expected;
            bb_pass = 0; bb_fail = 0;
            for (i = 0; i < 20; i = i + 1) bb_data[i] = i * 13 + 7;
            for (i = 0; i < 20; i = i + 1) begin
                expected = bb_data[i];
                timeout  = bit_period_ns(3'b100) * 15;
                fork
                    drive_rx_frame(expected, 2'b00, 0, 0);
                    wait_rx_done(timeout, got_rx, pe_cap, fe_cap);
                join
                if (got_rx && rx_data === expected && !pe_cap && !fe_cap)
                    bb_pass = bb_pass + 1;
                else begin
                    $display("  Byte[%0d]: expected %h got %h", i, expected, rx_data);
                    bb_fail = bb_fail + 1;
                end
            end
            if (bb_fail == 0)
                report_pass("TC7_BACK_TO_BACK_20_BYTES");
            else begin
                $display("  %0d/20 bytes failed", bb_fail);
                report_fail("TC7_BACK_TO_BACK_20_BYTES", "Some bytes corrupted");
            end
        end

        // =====================================================================
        // TC8 — All parity modes
        // =====================================================================
        $display("\n--- TC8: All parity modes ---");
        baud_sel = 3'b100;

        parity_sel = 2'b00;
        timeout = bit_period_ns(3'b100) * 15;
        fork
            drive_rx_frame(8'hC3, 2'b00, 0, 0);
            wait_rx_done(timeout, got_rx, pe_cap, fe_cap);
        join
        if (got_rx && rx_data === 8'hC3 && !pe_cap && !fe_cap)
            report_pass("TC8_NO_PARITY");
        else report_fail("TC8_NO_PARITY", "Failed 8-N-1");

        #(bit_period_ns(3'b100));
        parity_sel = 2'b01;
        timeout = bit_period_ns(3'b100) * 15;
        fork
            drive_rx_frame(8'hC3, 2'b01, 0, 0);
            wait_rx_done(timeout, got_rx, pe_cap, fe_cap);
        join
        if (got_rx && rx_data === 8'hC3 && !pe_cap && !fe_cap)
            report_pass("TC8_EVEN_PARITY");
        else begin
            $display("  rx_data=%h pe=%0b", rx_data, pe_cap);
            report_fail("TC8_EVEN_PARITY", "Failed 8-E-1");
        end

        #(bit_period_ns(3'b100));
        parity_sel = 2'b10;
        timeout = bit_period_ns(3'b100) * 15;
        fork
            drive_rx_frame(8'hC3, 2'b10, 0, 0);
            wait_rx_done(timeout, got_rx, pe_cap, fe_cap);
        join
        if (got_rx && rx_data === 8'hC3 && !pe_cap && !fe_cap)
            report_pass("TC8_ODD_PARITY");
        else begin
            $display("  rx_data=%h pe=%0b", rx_data, pe_cap);
            report_fail("TC8_ODD_PARITY", "Failed 8-O-1");
        end

        // =====================================================================
        // Summary
        // =====================================================================
        $display("\n=================================================================");
        $display("  SCOREBOARD SUMMARY");
        $display("  PASS : %0d", pass_count);
        $display("  FAIL : %0d", fail_count);
        $display("  TOTAL: %0d", pass_count + fail_count);
        $display("=================================================================\n");

        if (fail_count == 0)
            $display("*** ALL TESTS PASSED ***");
        else
            $display("*** %0d TEST(S) FAILED -- review log above ***", fail_count);

        $stop;
    end

    initial begin
        $dumpfile("uart_sim.vcd");
        $dumpvars(0, tb_uart_controller);
    end

    initial begin
        #(500_000_000);
        $display("[WATCHDOG] Timeout");
        $stop;
    end

endmodule
