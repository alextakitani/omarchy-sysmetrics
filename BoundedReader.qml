import QtQuick
import Quickshell.Io

// A procfs reader whose byte ceiling is enforced BEFORE the payload exists.
//
// FileView cannot do this. Its read completes in full and the whole file is
// materialised in the shared shell before `onLoaded` fires, so any check
// written inside that handler -- on text(), or on data().byteLength -- runs
// after the allocation it is meant to prevent. Measured on a real quickshell
// against an 80 MB file: RSS at the first line of onLoaded is already +225 MB,
// and the gate that then drops the payload reclaims none of it. FileView
// exposes no size limit, so the ceiling has to move to the producer.
//
// `head -c` is that producer: it stops reading at the ceiling, so the shell
// never sees more than `maxBytes` no matter how large the file is. Same 80 MB
// file through this path costs +2 MB.
//
// The cost is a subprocess per read (~0.77 ms, against ~0.005 ms for a
// FileView read), which is why this is NOT used for every reader -- only for
// the files whose size something outside this plugin decides. Files the
// kernel bounds to a single page stay on FileView; see Readers.qml.
Item {
    id: root

    property string path: ""
    property int maxBytes: 262144
    property bool running: false

    // Emitted with the file's contents, capped at maxBytes. Output that
    // reaches the ceiling is treated as truncated and reported as "" --
    // a missing reading beats a torn one parsed as fact.
    signal read(string text)

    function reload() {
        if (root.path === "" || proc.running) return
        proc.running = true
    }

    Process {
        id: proc
        command: ["head", "-c", String(root.maxBytes), root.path]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                // At the ceiling means the file was at least maxBytes: the
                // tail was cut, so the last row is unreliable. Fail closed.
                if (text.length >= root.maxBytes) root.read("")
                else root.read(text)
            }
        }
    }
}
