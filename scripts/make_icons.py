"""Generate the original H icon without external graphics dependencies."""
from pathlib import Path
import struct
import zlib

def png(size):
    pixels = bytearray()
    for y in range(size):
        pixels.append(0)
        for x in range(size):
            a, b = x/size, y/size
            color = (20, 34, 57)
            if (.29<a<.39 or .61<a<.71) and .24<b<.76 or .29<a<.71 and .45<b<.55:
                color = (144, 184, 255)
            if (a-.74)**2+(b-.76)**2 < .075**2:
                color = (97, 225, 174)
            pixels.extend(color)
    def chunk(name, data):
        return struct.pack('>I', len(data))+name+data+struct.pack('>I', zlib.crc32(name+data))
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR', struct.pack('>2I5B', size, size, 8, 2, 0, 0, 0))+chunk(b'IDAT', zlib.compress(pixels))+chunk(b'IEND', b'')

if __name__ == '__main__':
    directory = Path(__file__).resolve().parents[1]/'app/Resources'
    directory.mkdir(exist_ok=True)
    for name, size in [('Icon60@2x.png',120), ('Icon60@3x.png',180)]:
        (directory/name).write_bytes(png(size))
