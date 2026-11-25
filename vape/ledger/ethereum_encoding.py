"""Small stdlib ABI/Keccak/RLP helpers for the isolated test adapter, not a signer."""
_MASK = (1 << 64) - 1
_RC = (0x1,0x8082,0x800000000000808a,0x8000000080008000,0x808b,0x80000001,
       0x8000000080008081,0x8000000000008009,0x8a,0x88,0x80008009,0x8000000a,
       0x8000808b,0x800000000000008b,0x8000000000008089,0x8000000000008003,
       0x8000000000008002,0x8000000000000080,0x800a,0x800000008000000a,
       0x8000000080008081,0x8000000000008080,0x80000001,0x8000000080008008)
_ROT = ((0,36,3,41,18),(1,44,10,45,2),(62,6,43,15,61),(28,55,25,21,56),(27,20,39,8,14))


def keccak256(data):
    state = [0] * 25
    padded = bytearray(data)
    padded.append(1)  # Ethereum Keccak domain, NOT FIPS SHA3's 0x06
    padded.extend(b'\x00' * ((136 - len(padded) % 136) % 136))
    padded[-1] |= 128
    for offset in range(0, len(padded), 136):
        for i in range(17):
            state[i] ^= int.from_bytes(padded[offset+i*8:offset+i*8+8], 'little')
        for rc in _RC:
            c = [state[x]^state[x+5]^state[x+10]^state[x+15]^state[x+20] for x in range(5)]
            d = [c[(x-1)%5] ^ ((c[(x+1)%5]<<1 | c[(x+1)%5]>>63) & _MASK) for x in range(5)]
            b = [0]*25
            for x in range(5):
                for y in range(5):
                    value = state[x+5*y] ^ d[x]
                    shift = _ROT[x][y]
                    b[y+5*((2*x+3*y)%5)] = ((value<<shift) | (value>>(64-shift))) & _MASK
            for x in range(5):
                for y in range(5):
                    state[x+5*y] = b[x+5*y] ^ ((~b[(x+1)%5+5*y]) & b[(x+2)%5+5*y])
            state[0] ^= rc
    return b''.join(value.to_bytes(8, 'little') for value in state)[:32]


def encode_call(signature, words):
    if not all(isinstance(word, bytes) and len(word) == 32 for word in words):
        raise ValueError('ABI words must each be 32 bytes')
    return '0x' + (keccak256(signature.encode())[:4] + b''.join(words)).hex()


def rlp(value):
    if isinstance(value, int):
        if value < 0:
            raise ValueError('Negative RLP integer')
        value = value.to_bytes((value.bit_length()+7)//8, 'big')
    if isinstance(value, list):
        encoded = b''.join(rlp(item) for item in value)
        base = 0xc0
    elif isinstance(value, bytes):
        if len(value) == 1 and value[0] < 0x80:
            return value
        encoded, base = value, 0x80
    else:
        raise ValueError('Unsupported RLP value')
    size = len(encoded)
    if size < 56:
        return bytes([base+size])+encoded
    length = size.to_bytes((size.bit_length()+7)//8, 'big')
    return bytes([base+55+len(length)])+length+encoded


def decode_legacy(raw):
    def item(start):
        if start >= len(raw):
            raise ValueError('Truncated RLP')
        prefix = raw[start]
        if prefix < 0x80:
            return raw[start:start+1], start+1
        is_list = prefix >= 0xc0
        base = 0xc0 if is_list else 0x80
        length = prefix-base
        pos = start+1
        if length > 55:
            count = length-55
            if pos+count > len(raw):
                raise ValueError('Truncated length')
            length = int.from_bytes(raw[pos:pos+count], 'big')
            pos += count
        end = pos+length
        if end > len(raw):
            raise ValueError('Truncated value')
        if not is_list:
            return raw[pos:end], end
        values = []
        while pos < end:
            value, pos = item(pos)
            values.append(value)
        if pos != end:
            raise ValueError('Invalid list boundary')
        return values, end
    values, end = item(0)
    if end != len(raw) or not isinstance(values, list) or len(values) != 9 or not all(isinstance(x, bytes) for x in values):
        raise ValueError('Only nine-field legacy signed transactions are accepted')
    if rlp(values) != raw:
        raise ValueError('Noncanonical RLP')
    for index in (0,1,2,4,6,7,8):
        if values[index].startswith(b'\x00'):
            raise ValueError('Noncanonical integer')
    return values
