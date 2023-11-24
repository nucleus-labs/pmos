
description="A dummy target that does nothing. Useful for testing flags."

add_flag "-" "silly" "a very silly flag" 1 "silly-arg" "string" "a silly argument for a silly flag"
function flag_name_silly () {
    echo "[dummy][silly]: '$1'"
}

function target_dummy () {
    return
}