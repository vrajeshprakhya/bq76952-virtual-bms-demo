//======================================================================
// XezimBridge -- Renode peripheral that tunnels MMIO accesses from the
// emulated STM32 to the xezim SV-RNM board over TCP (lockstep RPC).
//
// Register map (doubleword, at sysbus 0x50000000):
//   0x00 W  PINS : bit0 SCL, bit1 SDA_PULL          -> "S scl sda\n"
//   0x04 W  ADV  : advance the board by <value> ns  -> "A ns\n"
//   0x08 R  SDA  : bus as sampled after the last command's ack
//   0x0C W  FIN  : end the board simulation          -> "F\n"
//
// Every command blocks until xezim's "K <sda>\n" ack, which carries
// the freshly-settled SDA -- so an SDA read is always consistent with
// everything the firmware has done so far, and board time moves only
// on ADV.  Blocking inside the MMIO handler is exactly the lockstep
// we want: the virtual CPU waits for the board.
//======================================================================
using System;
using System.IO;
using System.Net.Sockets;
using System.Threading;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;

namespace Antmicro.Renode.Peripherals
{
    public class XezimBridge : IDoubleWordPeripheral, IKnownSize
    {
        public XezimBridge()
        {
        }

        public long Size { get { return 0x100; } }

        public void Reset()
        {
        }

        public uint ReadDoubleWord(long offset)
        {
            if (offset == 0x08)
            {
                return lastSda;
            }
            return 0;
        }

        public void WriteDoubleWord(long offset, uint value)
        {
            switch (offset)
            {
            case 0x00:
                Rpc(string.Format("S {0} {1}\n", value & 1, (value >> 1) & 1));
                break;
            case 0x04:
                Rpc(string.Format("A {0}\n", value));
                break;
            case 0x0C:
                Rpc("F\n");
                this.Log(LogLevel.Info, "xezim board finished");
                break;
            }
        }

        private void Rpc(string cmd)
        {
            EnsureConnected();
            var data = System.Text.Encoding.ASCII.GetBytes(cmd);
            stream.Write(data, 0, data.Length);
            // read "K <sda>\n"
            var line = "";
            int b;
            while ((b = stream.ReadByte()) >= 0)
            {
                if (b == '\n') break;
                line += (char)b;
            }
            if (line.StartsWith("K "))
            {
                lastSda = (uint)(line[2] == '1' ? 1 : 0);
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
                    client = new TcpClient("127.0.0.1", 43601);
                    client.NoDelay = true;
                    stream = client.GetStream();
                    this.Log(LogLevel.Info, "connected to xezim bridge");
                    return;
                }
                catch (SocketException)
                {
                    Thread.Sleep(100);
                }
            }
            throw new Exception("XezimBridge: cannot reach xezim on 127.0.0.1:43601");
        }

        private TcpClient client;
        private NetworkStream stream;
        private uint lastSda = 1;
    }
}
