// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Test-only base64 decoder so a `tokenURI` can be turned back into JSON and parsed.
library Base64Decoder {
    function decode(string memory encoded) internal pure returns (bytes memory out) {
        bytes memory data = bytes(encoded);
        uint256 len = data.length;
        if (len == 0) return out;
        require(len % 4 == 0, "base64: bad length");

        uint256 padding = 0;
        if (data[len - 1] == "=") padding++;
        if (data[len - 2] == "=") padding++;

        out = new bytes(len / 4 * 3 - padding);
        uint256 o = 0;
        for (uint256 i = 0; i < len; i += 4) {
            uint256 chunk = (_value(data[i]) << 18) | (_value(data[i + 1]) << 12) | (_value(data[i + 2]) << 6)
                | _value(data[i + 3]);
            out[o++] = bytes1(uint8(chunk >> 16));
            if (o < out.length) out[o++] = bytes1(uint8(chunk >> 8));
            if (o < out.length) out[o++] = bytes1(uint8(chunk));
        }
    }

    function _value(bytes1 c) private pure returns (uint256) {
        uint8 v = uint8(c);
        if (v >= 65 && v <= 90) return v - 65; // A-Z
        if (v >= 97 && v <= 122) return v - 97 + 26; // a-z
        if (v >= 48 && v <= 57) return v - 48 + 52; // 0-9
        if (c == "+") return 62;
        if (c == "/") return 63;
        if (c == "=") return 0;
        revert("base64: bad character");
    }

    /// @dev Strips a `data:<mime>;base64,` prefix and decodes the rest.
    function decodeDataUri(string memory uri) internal pure returns (bytes memory) {
        bytes memory b = bytes(uri);
        uint256 start = 0;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ",") {
                start = i + 1;
                break;
            }
        }
        require(start > 0, "not a data uri");
        bytes memory payload = new bytes(b.length - start);
        for (uint256 i = 0; i < payload.length; i++) {
            payload[i] = b[start + i];
        }
        return decode(string(payload));
    }
}
