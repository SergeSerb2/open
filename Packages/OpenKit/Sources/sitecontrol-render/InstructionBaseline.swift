import Darwin
import Foundation

/// Versioned harness evidence, independent of App and library targets.
enum InstructionBaseline {
    struct Machine: Decodable {
        let cpuBrand: String
        let osBuild: String
        let coldOpenInstructions: UInt64
        let simpleEditorOpenInstructions: UInt64?
        var limit: UInt64 { coldOpenInstructions + (coldOpenInstructions+9)/10 }
    }
    private struct Fixture: Decodable {
        let version: Int
        let machines: [Machine]
    }
    static func current() throws -> (key: String,machine: Machine?) {
        func sysctl(_ name: String) throws -> String {
            var size = 0
            guard sysctlbyname(name,nil,&size,nil,0)==0,size>0,size<=256 else { throw CLIError(description: "cannot read machine key \(name)") }
            var bytes = [CChar](repeating: 0,count: size)
            guard sysctlbyname(name,&bytes,&size,nil,0)==0 else { throw CLIError(description: "cannot read machine key \(name)") }
            return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },as: UTF8.self)
        }
        let brand = try sysctl("machdep.cpu.brand_string"),build = try sysctl("kern.osversion")
        guard let url = Bundle.module.url(forResource: "instruction-baselines",withExtension: "json",subdirectory: "Fixtures") else { throw CLIError(description: "missing instruction baseline fixture") }
        let data = try Data(contentsOf: url)
        guard data.count<=16_384 else { throw CLIError(description: "instruction baseline fixture exceeds 16 KiB") }
        let fixture = try JSONDecoder().decode(Fixture.self,from: data)
        guard fixture.version==1,fixture.machines.count<=32,
              fixture.machines.allSatisfy({ machine in
                  machine.coldOpenInstructions>0 && machine.coldOpenInstructions<UInt64.max/2 &&
                  (machine.simpleEditorOpenInstructions.map { $0>0 && $0<UInt64.max/2 } ?? true)
              }),
              Set(fixture.machines.map { $0.cpuBrand+"|"+$0.osBuild }).count==fixture.machines.count else {
            throw CLIError(description: "invalid instruction baseline fixture")
        }
        return (brand+" / "+build,fixture.machines.first { $0.cpuBrand==brand && $0.osBuild==build })
    }
}
