// Keeps the GPU busy with a Metal compute kernel for N seconds (default 10).
// Used to prove the GPU readout reacts to real load.
import Foundation
import Metal

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "10") ?? 10
guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    FileHandle.standardError.write(Data("No Metal device\n".utf8))
    exit(1)
}

let source = """
#include <metal_stdlib>
using namespace metal;
kernel void burn(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    float x = float(id) * 0.0001;
    for (int i = 0; i < 2048; i++) { x = fma(sin(x), cos(x), 1.0001); }
    out[id] = x;
}
"""
let library = try device.makeLibrary(source: source, options: nil)
let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "burn")!)
let count = 1 << 20
let buffer = device.makeBuffer(length: count * MemoryLayout<Float>.size, options: .storageModePrivate)!
let threads = MTLSize(width: pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1)

let deadline = Date().addingTimeInterval(seconds)
var inFlight: [MTLCommandBuffer] = []
while Date() < deadline {
    let commands = queue.makeCommandBuffer()!
    let encoder = commands.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(buffer, offset: 0, index: 0)
    encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: threads)
    encoder.endEncoding()
    commands.commit()
    inFlight.append(commands)
    // Keep a couple of buffers queued so the GPU never idles between dispatches.
    if inFlight.count > 2 { inFlight.removeFirst().waitUntilCompleted() }
}
inFlight.forEach { $0.waitUntilCompleted() }
