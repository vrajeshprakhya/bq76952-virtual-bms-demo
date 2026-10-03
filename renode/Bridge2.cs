//======================================================================
// XezimBridge2 -- v2: VIRTUAL-TIME QUANTUM COUPLING.
//
// v1 let the firmware declare its delays (a write to an ADV register)
// and board time moved only on those declarations: compute was free.
// v2 removes the ADV register entirely.  Instead:
//
//   * A clock entry fires every QUANTUM of the machine's VIRTUAL time
//     (i.e. as the emulated CPU actually executes) and advances the
//     xezim board by exactly that much ("A <ns>").  Firmware compute
//     now costs board time, because CPU virtual time IS board time.
//   * Every pin access first flushes the un-synced remainder of the
//     current quantum, so I2C edges land at the correct virtual
//     instant (lockstep fidelity during bus activity, quantum speed
//     between it).
//   * Each ack carries SDA and ALERT ("K <sda> <alert>").  A rising
//     ALERT pulses the IRQ GPIO, which the .repl wires to the NVIC:
//     the firmware learns of a board event by interrupt, mid-
//     execution, instead of at its next poll.
//
// Register map (doubleword, at sysbus 0x60000100):
//   0x00 W  PINS    : bit0 SCL, bit1 SDA_PULL (flush + "S scl sda")
//   0x04 R  SDA     : bus as of the last sync
//   0x08 R  TNOW_LO : board time in ns, low word (as of last sync)
//   0x0C R  TNOW_HI : board time in ns, high word
//   0x10 W  FIN     : flush + "F"
//   0x14 R  ALERT   : level as of the last sync
//
// Determinism: quantum boundaries and flush deltas are pure virtual
// time, so runs are bit-reproducible.
//======================================================================
using System;
using System.Net.Sockets;
using System.Threading;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Time;

namespace Antmicro.Renode.Peripherals
{
    public class XezimBridge2 : IDoubleWordPeripheral, IKnownSize
    {
        public XezimBridge2(Machine machine, uint quantumUs = 10)
        {
            this.machine = machine;
            this.quantumNs = (ulong)quantumUs * 1000UL;
            IRQ = new GPIO();
            var freq = 1000000UL / (ulong)quantumUs;  // fires once per quantum
            machine.ClockSource.AddClockEntry(
                new ClockEntry(1, freq, QuantumFire, machine, "xezim-quantum"));
        }

        public GPIO IRQ { get; private set; }
        public long Size { get { return 0x100; } }

        public void Reset()
        {
        }

        public uint ReadDoubleWord(long offset)
        {
            switch (offset)
            {
            case 0x04: return lastSda;
            case 0x08: return (uint)(syncedNs & 0xffffffffUL);
            case 0x0C: return (uint)(syncedNs >> 32);
            case 0x14: return lastAlert;
            }
            return 0;
        }

        public void WriteDoubleWord(long offset, uint value)
        {
            switch (offset)
            {
            case 0x00:
                FlushTime();
                Rpc(string.Format("S {0} {1}\n", value & 1, (value >> 1) & 1));
                break;
            case 0x10:
                FlushTime();
                Rpc("F\n");
                finished = true;
                this.Log(LogLevel.Info, "xezim board finished");
                break;
            }
        }

        // one board-advance per quantum of CPU virtual time
        private void QuantumFire()
        {
            if (finished)
            {
                return;
            }
            Rpc(string.Format("A {0}\n", quantumNs));
            syncedNs += quantumNs;
            // level-held IRQ (a zero-width pulse from a clock callback
            // can be missed); the firmware's ISR masks itself via NVIC
            if (lastAlert == 1 && alertSeen == 0)
            {
                alertSeen = 1;
                this.Log(LogLevel.Info,
                         "ALERT from board at {0} ns; raising IRQ", syncedNs);
                IRQ.Set(true);
            }
            if (lastAlert == 0 && alertSeen == 1)
            {
                alertSeen = 0;
                IRQ.Set(false);
            }
        }

        // flush the un-synced tail of the current quantum before a pin
        // access, so bus edges land at the right virtual instant
        private void FlushTime()
        {
            var nowNs = (ulong)machine.ElapsedVirtualTime.TimeElapsed.TotalMicroseconds * 1000UL;
            if (nowNs > syncedNs)
            {
                var delta = nowNs - syncedNs;
                Rpc(string.Format("A {0}\n", delta));
                syncedNs = nowNs;
            }
        }

        private void Rpc(string cmd)
        {
            EnsureConnected();
            var data = System.Text.Encoding.ASCII.GetBytes(cmd);
            stream.Write(data, 0, data.Length);
            var line = "";
            int b;
            while ((b = stream.ReadByte()) >= 0)
            {
                if (b == '\n') break;
                line += (char)b;
            }
            // "K <sda> <alert>"
            var parts = line.Split(' ');
            if (parts.Length >= 2 && parts[0] == "K")
            {
                lastSda = (uint)(parts[1] == "1" ? 1 : 0);
                if (parts.Length >= 3)
                {
                    lastAlert = (uint)(parts[2] == "1" ? 1 : 0);
                }
            }
        }

        private void EnsureConnected()
        {
            if (client != null && client.Connected)
            {
                return;
            }
            for (var i = 0; i < 100; i++)
            {
                try
                {
                    client = new TcpClient("127.0.0.1", 43602);
                    client.NoDelay = true;
                    stream = client.GetStream();
                    this.Log(LogLevel.Info, "connected to xezim bridge2");
                    return;
                }
                catch (SocketException)
                {
                    Thread.Sleep(100);
                }
            }
            throw new Exception("XezimBridge2: cannot reach xezim on 127.0.0.1:43602");
        }

        private readonly Machine machine;
        private readonly ulong quantumNs;
        private ulong syncedNs;
        private TcpClient client;
        private NetworkStream stream;
        private uint lastSda = 1;
        private uint lastAlert;
        private uint alertSeen;
        private bool finished;
    }
}
