// Command obftest is a minimal stock MTProxy (obfuscated2) client used to check
// that a proxy accepts the plain obfuscated2 handshake and reaches a Telegram DC.
// It performs the handshake and one req_pq_multi, then expects a resPQ back.
package main

import (
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"flag"
	"fmt"
	"net"
	"os"
	"time"

	"github.com/9seconds/mtg/v2/mtglib/internal/obfuscation"
)

func frame(payload []byte) []byte {
	pad := (4 - len(payload)%4) % 4
	total := len(payload) + pad

	buf := make([]byte, 4+total)
	binary.LittleEndian.PutUint32(buf, uint32(total))
	copy(buf[4:], payload)

	if pad > 0 {
		_, _ = rand.Read(buf[4+len(payload):])
	}

	return buf
}

func main() {
	secretHex := flag.String("secret", "", "dd-prefixed or plain hex secret")
	addr := flag.String("addr", "127.0.0.1:3128", "proxy address")
	dcID := flag.Int("dc", 2, "datacenter id")
	timeout := flag.Duration("timeout", 15*time.Second, "overall timeout")
	flag.Parse()

	raw, err := hex.DecodeString(*secretHex)
	if err != nil || len(raw) == 0 {
		fmt.Println("FAIL: cannot decode secret:", err)
		os.Exit(1)
	}

	key := raw
	if len(raw) == 17 { // strip the dd marker
		key = raw[1:]
	}

	rawConn, err := net.DialTimeout("tcp", *addr, *timeout)
	if err != nil {
		fmt.Println("FAIL: cannot dial proxy:", err)
		os.Exit(1)
	}

	conn, ok := rawConn.(*net.TCPConn)
	if !ok {
		fmt.Println("FAIL: dialed connection is not TCP")
		os.Exit(1)
	}
	defer conn.Close() //nolint: errcheck

	_ = conn.SetDeadline(time.Now().Add(*timeout))

	client, err := obfuscation.Obfuscator{Secret: key}.SendHandshake(conn, *dcID)
	if err != nil {
		fmt.Println("FAIL: handshake:", err)
		os.Exit(1)
	}

	fmt.Println("OK: obfuscated2 handshake accepted")

	now := time.Now()
	msgID := uint64(now.Unix())<<32 | (uint64(now.Nanosecond()) &^ 3)

	body := make([]byte, 20)
	binary.LittleEndian.PutUint32(body, 0xbe7e8ef1) // req_pq_multi
	if _, err := rand.Read(body[4:]); err != nil {
		fmt.Println("FAIL: nonce:", err)
		os.Exit(1)
	}

	msg := make([]byte, 0, 40)
	msg = append(msg, make([]byte, 8)...) // auth_key_id = 0 (unencrypted)
	idBytes := make([]byte, 8)
	binary.LittleEndian.PutUint64(idBytes, msgID)
	msg = append(msg, idBytes...)
	lenBytes := make([]byte, 4)
	binary.LittleEndian.PutUint32(lenBytes, uint32(len(body)))
	msg = append(msg, lenBytes...)
	msg = append(msg, body...)

	if _, err := client.Write(frame(msg)); err != nil {
		fmt.Println("FAIL: cannot send req_pq_multi:", err)
		os.Exit(1)
	}

	hdr := make([]byte, 4)
	if _, err := client.Read(hdr); err != nil {
		fmt.Println("FAIL: no response header:", err)
		os.Exit(1)
	}

	length := binary.LittleEndian.Uint32(hdr)
	if length < 4 || length > 4096 {
		fmt.Printf("FAIL: implausible frame length %d\n", length)
		os.Exit(1)
	}

	resp := make([]byte, length)
	if _, err := client.Read(resp); err != nil {
		fmt.Println("FAIL: cannot read response:", err)
		os.Exit(1)
	}

	if len(resp) < 24 {
		fmt.Printf("FAIL: response too short (%d bytes)\n", len(resp))
		os.Exit(1)
	}

	// resp = auth_key_id(8) + msg_id(8) + msg_len(4) + body
	constructor := binary.LittleEndian.Uint32(resp[20:24])
	if constructor == 0x05162463 {
		fmt.Println("OK: resPQ received — the proxy reaches Telegram")
		os.Exit(0)
	}

	fmt.Printf("FAIL: unexpected constructor %#x\n", constructor)
	os.Exit(1)
}
