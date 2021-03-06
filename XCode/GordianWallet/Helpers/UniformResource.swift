//
//  UniformResource.swift
//  GordianWallet
//
//  Created by Peter on 09/08/20.
//  Copyright © 2020 Blockchain Commons, LLC. All rights reserved.
//

import Foundation
import URKit
import LibWally

enum URHelper {
    
    static func wordsToUr(words: String) -> String? {
        guard let bip39Mnemonic = try? BIP39Mnemonic(words: words) else { return nil }
        
        return entropyToUr(data: bip39Mnemonic.entropy.data)
    }
    
    static func entropyToUr(data: Data) -> String? {
        let wrapper:CBOR = .map([
            .unsignedInt(1) : .byteString(data.bytes),
        ])
        let cbor = Data(wrapper.cborEncode())
        do {
            let rawUr = try UR(type: "crypto-seed", cbor: cbor)
            return UREncoder.encode(rawUr)
        } catch {
            return nil
        }
    }
    
    static func shardToUr(data: Data) -> String? {
        let wrapper:CBOR = .tagged(.init(rawValue: 309), .byteString(data.bytes))
        let cbor = Data(wrapper.cborEncode())
        do {
            let rawUr = try UR(type: "crypto-sskr", cbor: cbor)
            return UREncoder.encode(rawUr)
        } catch {
            return nil
        }
    }
    
    static func urToEntropy(urString: String) -> (data: Data?, birthdate: UInt64?) {
        do {
            let ur = try URDecoder.decode(urString)
            let decodedCbor = try CBOR.decode(ur.cbor.bytes)
            guard case let CBOR.map(dict) = decodedCbor! else { return (nil, nil) }
            var data:Data?
            var birthdate:UInt64?
            for (key, value) in dict {
                switch key {
                case 1:
                    guard case let CBOR.byteString(byteString) = value else { fallthrough }
                    data = Data(byteString)
                case 2:
                    guard case let CBOR.unsignedInt(n) = value else { fallthrough }
                    birthdate = n
                default:
                    break
                }
            }
            return (data, birthdate)
        } catch {
            return (nil, nil)
        }
    }
    
    static func urToShard(sskrUr: String) -> String? {
        guard let ur = try? URDecoder.decode(sskrUr),
            let decodedCbor = try? CBOR.decode(ur.cbor.bytes),
            case let CBOR.tagged(_, cborRaw) = decodedCbor,
            case let CBOR.byteString(byteString) = cborRaw else { return nil }
        return Data(byteString).hexString
    }
    
    static func urToHdkey(urString: String) -> (isMaster: Bool?, keyData: String?, chainCode: String?) {
        do {
            let ur = try URDecoder.decode(urString)
            let decodedCbor = try CBOR.decode(ur.cbor.bytes)
            guard case let CBOR.map(dict) = decodedCbor! else { return (nil, nil, nil) }
            var isMaster:Bool?
            var keyData:String?
            var chainCode:String?
            for (key, value) in dict {
                switch key {
                case 1:
                    guard case let CBOR.boolean(b) = value else { fallthrough }
                    isMaster = b
                case 3:
                    guard case let CBOR.byteString(bs) = value else { fallthrough }
                    keyData = Data(bs).hexString
                case 4:
                    guard case let CBOR.byteString(bs) = value else { fallthrough }
                    chainCode = Data(bs).hexString
                default:
                    break
                }
            }
            return (isMaster, keyData, chainCode)
        } catch {
            return (nil, nil, nil)
        }
    }
    
    static func psbtUr(_ data: Data) -> UR? {
        let cbor = CBOR.byteString(data.bytes).cborEncode().data
        
        return try? UR(type: "crypto-psbt", cbor: cbor)
    }
    
    static func psbtUrToBase64Text(_ ur: UR) -> String? {
        guard let decodedCbor = try? CBOR.decode(ur.cbor.bytes),
            case let CBOR.byteString(bytes) = decodedCbor else {
                return nil
        }
        
        return Data(bytes).base64EncodedString()
    }
    
    static func xpubToUrHdkey(_ xpub: String, _ fingerprint: String, _ cointype: UInt64) -> String? {
        /// Only converts an exisiting seed to a cosigner (bip48) so we hard code origins
        let b58 = Base58.decode(xpub)
        let b58Data = Data(b58)
        let depth = b58Data.subdata(in: Range(4...4))
        let parentFingerprint = b58Data.subdata(in: Range(5...8))
        let childIndex = b58Data.subdata(in: Range(9...12))
        guard childIndex.hexString == "80000002" else { return nil }
        let chaincode = b58Data.subdata(in: Range(13...44))
        let keydata = b58Data.subdata(in: Range(45...77))
        
        var originsArray:[OrderedMapEntry] = []
        originsArray.append(.init(key: 1, value: .array([.unsignedInt(48), true, .unsignedInt(cointype), true, .unsignedInt(0), true, .unsignedInt(2), true])))
        originsArray.append(.init(key: 2, value: .unsignedInt(UInt64(fingerprint, radix: 16) ?? 0)))
        originsArray.append(.init(key: 3, value: .unsignedInt(UInt64(depth.hexString) ?? 0)))
        let originsWrapper = CBOR.orderedMap(originsArray)
        
        let useInfoWrapper:CBOR = .map([
            .unsignedInt(2) : .unsignedInt(cointype)
        ])
        
        guard let hexValue = UInt64(parentFingerprint.hexString, radix: 16) else { return nil }
        
        var hdkeyArray:[OrderedMapEntry] = []
        hdkeyArray.append(.init(key: 1, value: .boolean(false)))
        hdkeyArray.append(.init(key: 2, value: .boolean(false)))
        hdkeyArray.append(.init(key: 3, value: .byteString([UInt8](keydata))))
        hdkeyArray.append(.init(key: 4, value: .byteString([UInt8](chaincode))))
        hdkeyArray.append(.init(key: 5, value: .tagged(CBOR.Tag(rawValue: 305), useInfoWrapper)))
        hdkeyArray.append(.init(key: 6, value: .tagged(CBOR.Tag(rawValue: 304), originsWrapper)))
        hdkeyArray.append(.init(key: 8, value: .unsignedInt(hexValue)))
        let hdKeyWrapper = CBOR.orderedMap(hdkeyArray)
        
        guard let rawUr = try? UR(type: "crypto-hdkey", cbor: hdKeyWrapper) else { return nil }
        
        return UREncoder.encode(rawUr)
    }
    
    static func coinType(_ descriptorStruct: DescriptorStruct) -> UInt64 {
        var cointType:UInt64 = 0
        
        if descriptorStruct.chain == "Testnet" {
            cointType = 1
        }
        
        return cointType
    }
    
    static func msigOutput(_ descriptorStruct: DescriptorStruct) -> String? {
        let threshold = descriptorStruct.sigsRequired
        
        var hdkeyArray:[CBOR] = []
        
        for key in descriptorStruct.keysWithPath {
            guard let hdkey = cosignerToCborHdkey(key, false, coinType(descriptorStruct)) else { return nil }
            
            hdkeyArray.append(hdkey)
        }
        
        var keyThreshholdArray:[OrderedMapEntry] = []
        keyThreshholdArray.append(.init(key: 1, value: .unsignedInt(UInt64(threshold))))
        keyThreshholdArray.append(.init(key: 2, value: .array(hdkeyArray)))
        let keyThreshholdArrayCbor = CBOR.orderedMap(keyThreshholdArray)
        
        var msigTypeCbor:CBOR!
        
        if descriptorStruct.isBIP67 {
            let sortedMultisigTag:CBOR.Tag = .init(rawValue: 407)
            msigTypeCbor = .tagged(sortedMultisigTag, keyThreshholdArrayCbor)
        } else {
            let multisigTag:CBOR.Tag = .init(rawValue: 406)
            msigTypeCbor = .tagged(multisigTag, keyThreshholdArrayCbor)
        }
                        
        if descriptorStruct.isP2WPKH {
            
            let wshTag:CBOR.Tag = .init(rawValue: 401)
            let wrapper:CBOR = .tagged(wshTag, msigTypeCbor)
            
            print("hex: \(wrapper.cborEncode().data.hexString)")
            
            guard let rawUr = try? UR(type: "crypto-output", cbor: wrapper) else { return nil }
            
            return UREncoder.encode(rawUr)
            
        } else if descriptorStruct.isP2PKH {
            
            let p2shTag:CBOR.Tag = .init(rawValue: 403)
            let wrapper:CBOR = .tagged(p2shTag, msigTypeCbor)
            
            print("hex: \(wrapper.cborEncode().data.hexString)")
            
            guard let rawUr = try? UR(type: "crypto-output", cbor: wrapper) else { return nil }
            
            return UREncoder.encode(rawUr)
            
        } else if descriptorStruct.isP2SHP2WPKH {
            
            let shTag:CBOR.Tag = .init(rawValue: 404)
            let shWrapper:CBOR = .tagged(shTag, msigTypeCbor)
            
            let nestedTag:CBOR.Tag = .init(rawValue: 400)
            let wrapper:CBOR = .tagged(nestedTag, shWrapper)
                                    
            print("hex: \(wrapper.cborEncode().data.hexString)")
            
            guard let rawUr = try? UR(type: "crypto-output", cbor: wrapper) else { return nil }
            
            return UREncoder.encode(rawUr)
            
        } else {
            
            return nil
        }        
    }
    
    static func singleSigOutput(_ descriptorStruct: DescriptorStruct) -> String? {
        
        var processedOrigin = "\(descriptorStruct.keysWithPath[0])".replacingOccurrences(of: "'", with: "h")
        processedOrigin = "\(processedOrigin.split(separator: ")")[0])"
        
        guard let hdkey = cosignerToCborHdkey(processedOrigin, false, coinType(descriptorStruct)) else { return nil }
        
        let hdkeyTag:CBOR.Tag = .init(rawValue: 303)
        let hdKeyWrapper:CBOR = .tagged(hdkeyTag, hdkey)
                
        if descriptorStruct.isP2WPKH {
            
            let p2wpkhTag:CBOR.Tag = .init(rawValue: 404)
            let wrapper:CBOR = .tagged(p2wpkhTag, hdKeyWrapper)
                        
            print("hex: \(wrapper.cborEncode().data.hexString)")
            
            guard let rawUr = try? UR(type: "crypto-output", cbor: wrapper) else { return nil }
            
            return UREncoder.encode(rawUr)
            
        } else if descriptorStruct.isP2PKH {
            
            let p2pkhTag:CBOR.Tag = .init(rawValue: 403)
            let wrapper:CBOR = .tagged(p2pkhTag, hdKeyWrapper)
                        
            print("hex: \(wrapper.cborEncode().data.hexString)")
            
            guard let rawUr = try? UR(type: "crypto-output", cbor: wrapper) else { return nil }
            
            return UREncoder.encode(rawUr)
            
        } else if descriptorStruct.isP2SHP2WPKH {
            
            let p2wpkhTag:CBOR.Tag = .init(rawValue: 404)
            let nestedWrapper:CBOR = .tagged(p2wpkhTag, hdKeyWrapper)
            
            let shTag:CBOR.Tag = .init(rawValue: 400)
            let wrapper:CBOR = .tagged(shTag, nestedWrapper)
                        
            print("hex: \(wrapper.cborEncode().data.hexString)")
            
            guard let rawUr = try? UR(type: "crypto-output", cbor: wrapper) else { return nil }
            
            return UREncoder.encode(rawUr)
            
        } else {
            
            return nil
        }
    }
    
    static func accountToUrOutput(_ descriptor: String) -> String? {
        let descriptorParser = DescriptorParser()
        let descriptorStruct = descriptorParser.descriptor(descriptor)
        
        if descriptorStruct.isMulti {
            return msigOutput(descriptorStruct)
        } else {
            return singleSigOutput(descriptorStruct)
        }
    }
    
    static func origins(_ descStruct: DescriptorStruct) -> [CBOR] {
        var cborArray:[CBOR] = []
        for (i, item) in descStruct.derivation.split(separator: "/").enumerated() {
            if i != 0 && item != "m" {
                if item.contains("h") {
                    let processed = item.split(separator: "h")
                    
                    if let int = Int("\(processed[0])") {
                        let unsignedInt = CBOR.unsignedInt(UInt64(int))
                        cborArray.append(unsignedInt)
                        cborArray.append(CBOR.boolean(true))
                    }
                    
                } else if item.contains("'") {
                    let processed = item.split(separator: "'")
                    
                    if let int = Int("\(processed[0])") {
                        let unsignedInt = CBOR.unsignedInt(UInt64(int))
                        cborArray.append(unsignedInt)
                        cborArray.append(CBOR.boolean(true))
                    }
                } else {
                    if let int = Int("\(item)") {
                        let unsignedInt = CBOR.unsignedInt(UInt64(int))
                        cborArray.append(unsignedInt)
                        cborArray.append(CBOR.boolean(false))
                    }
                }
            }
        }
        
        return cborArray
    }
    
    static func cosignerToCborHdkey(_ cosigner: String, _ isPrivate: Bool, _ network: UInt64) -> CBOR? {
        let descriptorParser = DescriptorParser()
        let descriptor = "wsh(\(cosigner))"
        let descriptorStruct = descriptorParser.descriptor(descriptor)
        var key = descriptorStruct.accountXpub
        
        if isPrivate {
            key = descriptorStruct.accountXprv
        }
        
        /// Decodes our original extended key to base58 data.
        let b58 = Base58.decode(key)
        let b58Data = Data(b58)
        let depth = b58Data.subdata(in: Range(4...4))
        let parentFingerprint = b58Data.subdata(in: Range(5...8))
        //let childIndex = b58Data.subdata(in: Range(9...12))
       //guard childIndex.hexString == "80000002" || childIndex.hexString == "80000000" else { print("childIndex.hexString: \(childIndex.hexString)"); return nil }
        let chaincode = b58Data.subdata(in: Range(13...44))
        let keydata = b58Data.subdata(in: Range(45...77))
        
        var originsArray:[OrderedMapEntry] = []
        //let x = origins(descriptorStruct)
        //print("x: \(x)")
        //originsArray.append(.init(key: 1, value: origins(cosigner)))
        originsArray.append(.init(key: 1, value: .array(origins(descriptorStruct))))
        originsArray.append(.init(key: 2, value: .unsignedInt(UInt64(descriptorStruct.fingerprint, radix: 16) ?? 0)))
        originsArray.append(.init(key: 3, value: .unsignedInt(UInt64(depth.hexString) ?? 0)))
        let originsWrapper = CBOR.orderedMap(originsArray)
        
        let useInfoWrapper:CBOR = .map([
            .unsignedInt(2) : .unsignedInt(network)
        ])
        
        guard let hexValue = UInt64(parentFingerprint.hexString, radix: 16) else { return nil }
        
        var hdkeyArray:[OrderedMapEntry] = []
        hdkeyArray.append(.init(key: 1, value: .boolean(false)))
        hdkeyArray.append(.init(key: 2, value: .boolean(isPrivate)))
        hdkeyArray.append(.init(key: 3, value: .byteString([UInt8](keydata))))
        hdkeyArray.append(.init(key: 4, value: .byteString([UInt8](chaincode))))
        hdkeyArray.append(.init(key: 5, value: .tagged(CBOR.Tag(rawValue: 305), useInfoWrapper)))
        hdkeyArray.append(.init(key: 6, value: .tagged(CBOR.Tag(rawValue: 304), originsWrapper)))
        hdkeyArray.append(.init(key: 8, value: .unsignedInt(hexValue)))
        let hdKeyWrapper = CBOR.orderedMap(hdkeyArray)
        
        return hdKeyWrapper
    }
}
