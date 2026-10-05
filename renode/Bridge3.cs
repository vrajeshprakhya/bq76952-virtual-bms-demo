//======================================================================
// Bridge3.cs -- the I2C DRIVER RUNG.
//
// The firmware no longer touches pins at all: it programs the real
// STM32 I2C controller (Renode's STM32F7_I2C model, byte-level), and
// THIS file closes the gap to the pin-level board:
//
//   XezimPinMaster  -- owns the TCP link to the generic pin bridge
//      (out bit0 = SCL, bit1 = SDA_PULL; in bit0 = SDA) and performs
//      bit-banged MASTER transactions on the wires: the bus-functional
//      model moves out of the firmware and into the harness, where it
//      belongs.  Also runs the 10 us virtual-time quantum engine and
//      exposes TNOW/FIN registers at 0x60000200.
//   XezimI2CSlave   -- an II2CPeripheral registered on i2c1 at the
//      AFE's address: every byte-level transaction the controller
//      model delivers is executed as real edges on the board's bus.
//
// Honest timing note: a transaction's bus time (~90 us per byte at
// 100 kHz) is granted to the board while the CPU is stalled on the
// controller, approximating what the real controller's busy period
// costs; between transactions the quantum engine meters CPU
// execution as in the bench-like backend.
//======================================================================
using System;
using System.Collections.Generic;
using System.Net.Sockets;
using System.Threading;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.I2C;
using Antmicro.Renode.Time;

namespace Antmicro.Renode.Peripherals
{
    public class XezimPinMaster : IDoubleWordPeripheral, IKnownSize
    {
        public XezimPinMaster(Machine machine, uint quantumUs = 10,
                              int port = 43605)
        {
            this.port = port;
            quantumNs = (ulong)quantumUs * 1000UL;
            var freq = 1000000UL / (ulong)quantumUs;
            machine.ClockSource.AddClockEntry(
                new ClockEntry(1, freq, QuantumFire, machine, "xezim-q3"));
        }

        public long Size { get { return 0x100; } }
        public void Reset() { }

        public uint ReadDoubleWord(long offset)
        {
            switch (offset)
            {
            case 0x08: return (uint)(syncedNs & 0xffffffffUL);
            case 0x0C: return (uint)(syncedNs >> 32);
            }
            return 0;
        }

        public void WriteDoubleWord(long offset, uint value)
        {
            if (offset == 0x10)
            {
                lock (gate) { Rpc("F\n"); finished = true; }
            }
        }

        private void QuantumFire()
        {
            if (finished) return;
            lock (gate)
            {
                Rpc(string.Format("A {0}\n", quantumNs));
                syncedNs += quantumNs;
            }
        }

        // ---- pin-level I2C master, executed on the board's wires ----
        // out bit0 = SCL, bit1 = SDA_PULL (1 pulls SDA low)
        private void Pins(int scl, int pull)
        {
            Rpc(string.Format("S {0:x}\n", (scl & 1) | ((pull & 1) << 1)));
        }
        private void Gap()                      // quarter bit, 2.5 us
        {
            Rpc("A 2500\n");
            syncedNs += 2500;
        }
        private bool TxByte(byte b)             // returns ACK
        {
            for (var i = 7; i >= 0; i--)
            {
                var bit = ((b >> i) & 1) == 1 ? 0 : 1;   // pull if 0
                Pins(0, bit); Gap();
                Pins(1, bit); Gap(); Gap();
                Pins(0, bit); Gap();
            }
            Pins(0, 0); Gap();                  // release for slave ACK
            Pins(1, 0); Gap();
            var ack = lastSda == 0;
            Gap();
            Pins(0, 0); Gap();
            return ack;
        }
        private byte RxByte(bool ack)
        {
            var v = 0;
            for (var i = 7; i >= 0; i--)
            {
                Pins(0, 0); Gap();
                Pins(1, 0); Gap();
                v = (v << 1) | lastSda;
                Gap();
                Pins(0, 0); Gap();
            }
            var p = ack ? 1 : 0;                // master ACK pulls low
            Pins(0, p); Gap();
            Pins(1, p); Gap(); Gap();
            Pins(0, 0); Gap();
            return (byte)v;
        }
        private void Start()
        {
            Pins(1, 0); Gap();
            Pins(1, 1); Gap();
            Pins(0, 1); Gap();
        }
        private void Stop()
        {
            Pins(0, 1); Gap();
            Pins(1, 1); Gap();
            Pins(1, 0); Gap();
        }

        public void WriteTransaction(byte addr, byte[] data)
        {
            lock (gate)
            {
                Start();
                TxByte((byte)(addr << 1));
                foreach (var b in data) TxByte(b);
                Stop();
            }
        }
        public byte[] ReadTransaction(byte addr, int count)
        {
            lock (gate)
            {
                Start();
                TxByte((byte)((addr << 1) | 1));
                var r = new byte[count];
                for (var i = 0; i < count; i++)
                    r[i] = RxByte(i < count - 1);
                Stop();
                return r;
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
            // "K <in_hex> <alert>"
            var parts = line.Split(' ');
            if (parts.Length >= 2 && parts[0] == "K")
            {
                lastSda = (int)(Convert.ToUInt32(parts[1], 16) & 1);
            }
        }

        private void EnsureConnected()
        {
            if (client != null && client.Connected) return;
            for (var i = 0; i < 100; i++)
            {
                try
                {
                    client = new TcpClient("127.0.0.1", port);
                    client.NoDelay = true;
                    stream = client.GetStream();
                    this.Log(LogLevel.Info, "connected to xezim pin bridge");
                    return;
                }
                catch (SocketException) { Thread.Sleep(100); }
            }
            throw new Exception("XezimPinMaster: cannot reach xezim");
        }

        private readonly object gate = new object();
        private readonly int port;
        private readonly ulong quantumNs;
        private ulong syncedNs;
        private bool finished;
        private TcpClient client;
        private NetworkStream stream;
        private int lastSda = 1;
    }

    // byte-level slave on the controller's bus; executes everything as
    // pin-level transactions on the board
    public class XezimI2CSlave : II2CPeripheral
    {
        public XezimI2CSlave(XezimPinMaster master, byte address = 0x08)
        {
            this.master = master;
            this.address = address;
        }

        public void Write(byte[] data)
        {
            master.WriteTransaction(address, data);
        }

        public byte[] Read(int count = 1)
        {
            return master.ReadTransaction(address, count);
        }

        public void FinishTransmission() { }
        public void Reset() { }

        private readonly XezimPinMaster master;
        private readonly byte address;
    }
}
