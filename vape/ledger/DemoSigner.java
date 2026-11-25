// Disposable local-test signer using Bouncy Castle already bundled with verified Besu.
// No key files, network, wallets or user credentials. Secret arrives over stdin only.
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.math.BigInteger;
import java.util.HexFormat;
import org.bouncycastle.crypto.digests.SHA256Digest;
import org.bouncycastle.crypto.ec.CustomNamedCurves;
import org.bouncycastle.crypto.params.ECDomainParameters;
import org.bouncycastle.crypto.params.ECPrivateKeyParameters;
import org.bouncycastle.crypto.signers.ECDSASigner;
import org.bouncycastle.crypto.signers.HMacDSAKCalculator;

public class DemoSigner {
    public static void main(String[] args) throws Exception {
        var in = new BufferedReader(new InputStreamReader(System.in));
        var d = new BigInteger(in.readLine(), 16);
        var curve = CustomNamedCurves.getByName("secp256k1");
        var n = curve.getN();
        if (d.signum() <= 0 || d.compareTo(n) >= 0) throw new IllegalArgumentException("Invalid test scalar");
        var pub = curve.getG().multiply(d).normalize().getEncoded(false);
        System.out.println(HexFormat.of().formatHex(pub));
        var line = in.readLine();
        if (line == null || line.isEmpty()) return;
        var hash = HexFormat.of().parseHex(line);
        if (hash.length != 32) throw new IllegalArgumentException("Expected 32-byte hash");
        var signer = new ECDSASigner(new HMacDSAKCalculator(new SHA256Digest()));
        var domain = new ECDomainParameters(curve.getCurve(), curve.getG(), n, curve.getH());
        signer.init(true, new ECPrivateKeyParameters(d, domain));
        var signature = signer.generateSignature(hash);
        var kgen = new HMacDSAKCalculator(new SHA256Digest());
        kgen.init(n, d, hash);
        var point = curve.getG().multiply(kgen.nextK()).normalize();
        if (point.getAffineXCoord().toBigInteger().compareTo(n) >= 0)
            throw new IllegalStateException("Rare recovery case: create a fresh test transaction");
        int recovery = point.getAffineYCoord().toBigInteger().testBit(0) ? 1 : 0;
        if (signature[1].compareTo(n.shiftRight(1)) > 0) {
            signature[1] = n.subtract(signature[1]); recovery ^= 1;
        }
        System.out.println(signature[0].toString(16));
        System.out.println(signature[1].toString(16));
        System.out.println(recovery);
    }
}
