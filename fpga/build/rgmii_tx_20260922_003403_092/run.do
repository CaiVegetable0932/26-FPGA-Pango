onerror {quit -f -code 2}
onbreak {quit -f -code 3}
log -r /*
run -all
quit -f -code 0
