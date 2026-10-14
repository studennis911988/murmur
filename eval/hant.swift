// Converts each stdin line from Simplified to Traditional Chinese with ICU's
// Hans-Hant transform. Used by run_eval.py to score script-normalized MER.
import Foundation

let transform = StringTransform("Hans-Hant")
while let line = readLine(strippingNewline: true) {
    print(line.applyingTransform(transform, reverse: false) ?? line)
}
