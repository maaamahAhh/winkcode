module tui

// Workaround for upstream vlang/v#28677: SChannel TLS on Windows
// Maps UNISP_NAME_W to SCHANNEL_NAME so credentials initialize cleanly
#flag windows -DUNISP_NAME_W=SCHANNEL_NAME
