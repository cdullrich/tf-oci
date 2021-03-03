package main

import (
        "fmt"
        "log"
        "net/http"
        "os/exec"
)

type ociInfo struct {
    datetime []byte
    os []byte
    ip []byte
}

func main() {
    var err error
    var ociReturn ociInfo
    datecmd := exec.Command("date")
    ociReturn.datetime, err = datecmd.Output()
    if err != nil {
        log.Fatal(err)
    }
    ociReturn.os, err = exec.Command("uname", "-a").Output()
    if err != nil {
        log.Fatal(err)
    }
    ociReturn.ip, err = exec.Command("hostname", "-i").Output()
    if err != nil {
        log.Fatal(err)
    }

    fmt.Println(string(ociReturn.datetime))
    fmt.Println(string(ociReturn.os))
    fmt.Println(string(ociReturn.ip))

    http.HandleFunc("/", func(rw http.ResponseWriter, req *http.Request) {
        rw.Write([]byte(fmt.Sprintf("Date and Time-", string(ociReturn.datetime))))
        rw.Write([]byte(fmt.Sprintf("OS Information-", string(ociReturn.os))))
        rw.Write([]byte(fmt.Sprintf("IP Information-", string(ociReturn.datetime))))
    })
    fmt.Println(http.ListenAndServe(":30000", nil))
}