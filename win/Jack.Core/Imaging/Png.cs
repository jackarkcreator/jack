// Minimal PNG writer and reader (no System.Drawing): 8-bit gray or RGBA, non-interlaced.
// The writer stores every row with filter 0 and zlib-compresses with ZLibStream; the reader
// handles all five row filters (it reads the PNGs the Mac engine dumps through ImageIO).
using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;

namespace Jack.Core.Imaging;

public static class Png
{
    static readonly byte[] Signature = { 137, 80, 78, 71, 13, 10, 26, 10 };

    /// `channels` 1 = gray (colour type 0), 3 = RGB (2), 4 = RGBA (6).
    public static byte[] Encode(int width, int height, int channels, byte[] pixels)
    {
        byte colorType = channels switch { 1 => 0, 3 => 2, 4 => 6, _ => throw new ArgumentException("channels must be 1, 3 or 4") };
        int row = width * channels;
        if (pixels.Length != row * height) throw new ArgumentException("pixel buffer size does not match");
        using var ms = new MemoryStream();
        ms.Write(Signature);
        var ihdr = new byte[13];
        BinaryPrimitives.WriteInt32BigEndian(ihdr.AsSpan(0), width);
        BinaryPrimitives.WriteInt32BigEndian(ihdr.AsSpan(4), height);
        ihdr[8] = 8; ihdr[9] = colorType; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
        Chunk(ms, "IHDR", ihdr);
        using (var raw = new MemoryStream())
        {
            using (var z = new ZLibStream(raw, CompressionLevel.Optimal, leaveOpen: true))
            {
                for (int y = 0; y < height; y++)
                {
                    z.WriteByte(0);
                    z.Write(pixels, y * row, row);
                }
            }
            Chunk(ms, "IDAT", raw.ToArray());
        }
        Chunk(ms, "IEND", Array.Empty<byte>());
        return ms.ToArray();
    }

    static void Chunk(Stream s, string type, byte[] data)
    {
        Span<byte> len = stackalloc byte[4];
        BinaryPrimitives.WriteInt32BigEndian(len, data.Length);
        s.Write(len);
        var t = Encoding.ASCII.GetBytes(type);
        s.Write(t);
        s.Write(data);
        uint crc = Crc32.Update(Crc32.Update(0xFFFFFFFFu, t), data) ^ 0xFFFFFFFFu;
        BinaryPrimitives.WriteUInt32BigEndian(len, crc);
        s.Write(len);
    }

    public sealed record Image(int Width, int Height, int Channels, byte[] Pixels);

    /// Decodes an 8-bit, non-interlaced PNG into its own channels (1, 2, 3 or 4).
    public static Image Decode(byte[] png)
    {
        if (png.Length < 8 || !png.AsSpan(0, 8).SequenceEqual(Signature)) throw new InvalidDataException("not a PNG");
        int pos = 8, width = 0, height = 0, channels = 0;
        using var idat = new MemoryStream();
        while (pos + 8 <= png.Length)
        {
            int len = BinaryPrimitives.ReadInt32BigEndian(png.AsSpan(pos));
            string type = Encoding.ASCII.GetString(png, pos + 4, 4);
            var data = png.AsSpan(pos + 8, len);
            if (type == "IHDR")
            {
                width = BinaryPrimitives.ReadInt32BigEndian(data);
                height = BinaryPrimitives.ReadInt32BigEndian(data[4..]);
                byte depth = data[8], ct = data[9], interlace = data[12];
                if (depth != 8 || interlace != 0) throw new InvalidDataException($"unsupported PNG (depth {depth}, interlace {interlace})");
                channels = ct switch { 0 => 1, 4 => 2, 2 => 3, 6 => 4, _ => throw new InvalidDataException($"unsupported PNG colour type {ct}") };
            }
            else if (type == "IDAT") idat.Write(data);
            else if (type == "IEND") break;
            pos += 12 + len;
        }
        if (channels == 0) throw new InvalidDataException("PNG has no IHDR");
        int stride = width * channels;
        var raw = new byte[(stride + 1) * height];
        idat.Position = 0;
        using (var z = new ZLibStream(idat, CompressionMode.Decompress))
        {
            int got = 0;
            while (got < raw.Length)
            {
                int n = z.Read(raw, got, raw.Length - got);
                if (n == 0) throw new InvalidDataException("PNG data ends early");
                got += n;
            }
        }
        var px = new byte[stride * height];
        int bpp = channels;
        for (int y = 0; y < height; y++)
        {
            int f = raw[y * (stride + 1)];
            int src = y * (stride + 1) + 1, dst = y * stride, up = dst - stride;
            for (int x = 0; x < stride; x++)
            {
                int a = x >= bpp ? px[dst + x - bpp] : 0;
                int b = y > 0 ? px[up + x] : 0;
                int c = x >= bpp && y > 0 ? px[up + x - bpp] : 0;
                int v = raw[src + x];
                v += f switch
                {
                    0 => 0,
                    1 => a,
                    2 => b,
                    3 => (a + b) >> 1,
                    4 => Paeth(a, b, c),
                    _ => throw new InvalidDataException($"bad PNG filter {f}"),
                };
                px[dst + x] = (byte)v;
            }
        }
        return new Image(width, height, channels, px);
    }

    static int Paeth(int a, int b, int c)
    {
        int p = a + b - c, pa = Math.Abs(p - a), pb = Math.Abs(p - b), pc = Math.Abs(p - c);
        return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
    }
}

public static class Crc32
{
    static readonly uint[] Table = Enumerable.Range(0, 256).Select(i =>
    {
        uint c = (uint)i;
        for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        return c;
    }).ToArray();

    public static uint Update(uint crc, ReadOnlySpan<byte> data)
    {
        foreach (var b in data) crc = Table[(crc ^ b) & 0xFF] ^ (crc >> 8);
        return crc;
    }
}

public static class Fnv
{
    /// FNV-1a 64, as the Mac dump writes it (16 lowercase hex digits).
    public static string Hash(ReadOnlySpan<byte> data)
    {
        ulong h = 0xcbf29ce484222325UL;
        foreach (var b in data) { h ^= b; h *= 0x100000001b3UL; }
        return h.ToString("x16");
    }
}
