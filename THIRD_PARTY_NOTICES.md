# Third-party notices

ZiServer's original Zig, C, JavaScript, CSS, HTML, documentation, and example
code is licensed under the BSD 2-Clause License in [`LICENSE`](LICENSE), unless
a file or directory says otherwise.

The components below retain their own licenses. They are not relicensed under
ZiServer's BSD 2-Clause License. When distributing a ZiServer binary together
with third-party runtime libraries, include this file and the applicable files
from [`LICENSES/`](LICENSES/).

| Component | How ZiServer uses it | License | Local license text |
| --- | --- | --- | --- |
| OpenSSL | TLS 1.2/1.3, cryptography, ALPN, and QUIC TLS | Apache License 2.0 | [`LICENSES/Apache-2.0.txt`](LICENSES/Apache-2.0.txt) |
| nghttp2 | HTTP/2 framing, HPACK, and stream management | MIT | [`LICENSES/nghttp2.txt`](LICENSES/nghttp2.txt) |
| ngtcp2 | Optional QUIC transport for native HTTP/3 | MIT | [`LICENSES/ngtcp2.txt`](LICENSES/ngtcp2.txt) |
| nghttp3 | Optional HTTP/3 framing and QPACK | MIT | [`LICENSES/nghttp3.txt`](LICENSES/nghttp3.txt) |
| sfparse | Transitive structured-field parser dependency of recent nghttp3 builds | MIT | [`LICENSES/sfparse.txt`](LICENSES/sfparse.txt) |
| GSAP 3.12.5 and ScrollTrigger 3.12.5 | Demo-site animation assets under `src/public/assets/` | GreenSock Standard License | [`LICENSES/GSAP-3.12.5.txt`](LICENSES/GSAP-3.12.5.txt) |

OpenSSL, nghttp2, ngtcp2, nghttp3, and sfparse are linked as external libraries and are
not copied into ZiServer's source tree. Windows builds may install their runtime
DLLs beside `ziserver.exe`; those DLLs remain covered by their upstream terms.

GSAP and ScrollTrigger are directly distributed in the source tree. They are
separately licensed third-party assets, not BSD-licensed ZiServer code and not
represented here as OSI-approved open-source software. Their embedded license
headers must be retained. The authoritative terms are published by GreenSock:
<https://gsap.com/standard-license/>.
