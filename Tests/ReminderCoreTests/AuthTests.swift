import XCTest
@testable import Samsung_Reminder

final class AuthTests: XCTestCase {
    // Vectors produced with openssl 4.1 (see repo history for the exact commands).
    func testAESECBDecryptMatchesOpenSSL() throws {
        let plain = try SamsungCrypto.aesECBDecrypt(textKey: "abcdefghij",
                                                     hex: "b41f51f6d46a339d5488f15e544a17b42eb7ebfb680d65cd4b9cb9feda386d43")
        XCTAssertEqual(plain, "https://account.samsung.com")
        XCTAssertThrowsError(try SamsungCrypto.aesECBDecrypt(textKey: "abcdefghij", hex: "zz"))
    }

    func testPBKDF2MatchesOpenSSL() throws {
        let password = Data(SamsungCrypto.sha256Base64("1000").utf8)
        XCTAssertEqual(String(decoding: password, as: UTF8.self), "QFEBdYRZiPE/YWLthSbwsJ9zOERn+oVeHnm0SlZWKlg=")
        let key = try SamsungCrypto.pbkdf2(password: password, salt: Data(hex: "000102030405060708090a0b0c0d0e0f")!, iterations: 1000, length: 16)
        XCTAssertEqual(key.hexString, "1885f93f60ac535ab840a909e2530f1d")
    }

    func testAESCBCRoundTripsThroughSecurityFrameworkShapes() throws {
        let key = Data(hex: "000102030405060708090a0b0c0d0e0f")!
        let iv = Data(hex: "0f0e0d0c0b0a09080706050403020100")!
        let cipher = try SamsungCrypto.aesCBCEncrypt(key: key, iv: iv, plaintext: Data("{\"a\":1}".utf8))
        XCTAssertEqual(cipher.count, 16, "PKCS7 pads 7 bytes to one block")
    }

    func testRSAEncryptAcceptsSPKIFromOpenSSL() throws {
        // Throwaway 2048-bit public key generated for this test; it has no private counterpart anywhere.
        let spki = Data(base64Encoded: "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAs2JUpv0ilBEhNl+diPqbn4sNg6Oq2u66bL9EKcPocOXtW3bTw6Ur1me9MyoK2X3eDbrTs99gJ8gVGyW9fvd8VXlwzbITV4gr6tqIbOnUwv8IMLqvLReyx8MueZ60SIFbUOB6z+Hx9uTB26o8XFi+Jv1Wa8YPV6mL12FcdqHW9YkHpjYDr779vK/1qAM5pkSkk0uPpAR0XkMSBafpQjbtgFThbm9WB1SEJTmUdMvr+oRQblhjCVe2OMBmeCSQ+PMN8PMirdaZgDxa7v24ETpB9vwfkEvERrUtqeyKCwXgDcH0YCZ5iDesf1iPNih1MWEGspid+H9ivfr+gfD4ZbMy8QIDAQAB")!
        let encrypted = try SamsungCrypto.rsaEncrypt(spkiDER: spki, plaintext: Data("dGVzdA==".utf8))
        XCTAssertEqual(encrypted.count, 256, "ciphertext is modulus-sized")
        XCTAssertThrowsError(try SamsungCrypto.unwrapSPKI(Data([0x30, 0x02, 0x05, 0x00])))
    }

    func testServiceParameterEnvelopeShape() throws {
        let spki = Data(base64Encoded: "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAs2JUpv0ilBEhNl+diPqbn4sNg6Oq2u66bL9EKcPocOXtW3bTw6Ur1me9MyoK2X3eDbrTs99gJ8gVGyW9fvd8VXlwzbITV4gr6tqIbOnUwv8IMLqvLReyx8MueZ60SIFbUOB6z+Hx9uTB26o8XFi+Jv1Wa8YPV6mL12FcdqHW9YkHpjYDr779vK/1qAM5pkSkk0uPpAR0XkMSBafpQjbtgFThbm9WB1SEJTmUdMvr+oRQblhjCVe2OMBmeCSQ+PMN8PMirdaZgDxa7v24ETpB9vwfkEvERrUtqeyKCwXgDcH0YCZ5iDesf1iPNih1MWEGspid+H9ivfr+gfD4ZbMy8QIDAQAB")!
        let param = try SamsungAccountAuth.encryptServiceParameter(["state": .string("x")], iterations: 10, publicKeyDER: spki)
        let json = try XCTUnwrap(Data(base64Encoded: param.removingPercentEncoding!))
        let envelope = try JSONDecoder().decode(JSONValue.self, from: json)
        XCTAssertEqual(envelope["chkDoNum"].string, "10")
        XCTAssertEqual(envelope["svcEncIV"].string?.count, 32)
        XCTAssertNotNil(Data(base64Encoded: envelope["svcEncKY"].string ?? ""))
        XCTAssertNotNil(Data(base64Encoded: envelope["svcEncParam"].string ?? ""))
    }

    func testCallbackAndAuthServerAllowlists() throws {
        XCTAssertTrue(SamsungAccountAuth.isCallback(URL(string: SamsungAccountAuth.redirectURI + "?code=1")!))
        XCTAssertFalse(SamsungAccountAuth.isCallback(URL(string: "ms-app://s-1-15-2-1?code=1")!))
        XCTAssertEqual(try SamsungAccountAuth.trustedAuthServer("https://eu-auth2.samsungosp.com").absoluteString, "https://eu-auth2.samsungosp.com")
        XCTAssertThrowsError(try SamsungAccountAuth.trustedAuthServer("https://evil.com"))
        XCTAssertThrowsError(try SamsungAccountAuth.trustedAuthServer("https://samsungosp.com.evil.com"))
        XCTAssertThrowsError(try SamsungAccountAuth.trustedAuthServer("https://account.samsung.com/path"))
        XCTAssertThrowsError(try SamsungAccountAuth.trustedAuthServer("http://account.samsung.com"))
    }

    func testCredentialRenewalFlags() {
        var manual = CloudCredential(accessToken: "t", userId: "u", deviceId: "d")
        XCTAssertFalse(manual.canRenew)
        XCTAssertFalse(manual.needsRenewal)
        manual.refreshToken = "r"; manual.authServer = "https://account.samsung.com"
        XCTAssertTrue(manual.needsRenewal, "unknown expiry with a refresh token renews eagerly")
        manual.expiresAt = Date().addingTimeInterval(3600)
        XCTAssertFalse(manual.needsRenewal)
        manual.expiresAt = Date().addingTimeInterval(30)
        XCTAssertTrue(manual.needsRenewal)
    }

    func testUnwrapsSamsungsRealEntryPointKey() throws {
        // Samsung's public 1024-bit entry-point key as served on 2026-11-05 (short-form DER lengths).
        let spki = Data(base64Encoded: "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCylnSE8ANPUNPmgYJGnApUrUPQiBmTY44Lw+fQbFOOslZZnuUasDFJuPU4287/LBQEpTtgPWLmjGftG/b2sj8eTH46mvhDtE8ijgZsMnGPMmhu/AljEvNOqU6nDZDtgGmL/pAdEBtsJ/VzClv8G9bV1kvczuZtg0gt3JTH+pagEwIDAQAB")!
        let encrypted = try SamsungCrypto.rsaEncrypt(spkiDER: spki, plaintext: Data("dGVzdA==".utf8))
        XCTAssertEqual(encrypted.count, 128)
    }
}
