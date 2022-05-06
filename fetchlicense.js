var system = require("system");
var page = require('webpage').create();


var i;
for (i = 1; i < system.args.length; i += 2) {
    if (system.args[i] === "--username" || system.args[i] === "-u") {
        username = system.args[i + 1];
    }

    if (system.args[i] === "--password" || system.args[i] === "-p") {
        password = system.args[i + 1];
    }

    if (system.args[i] === "--apppoints" || system.args[i] === "-a") {
        numberOfAppPoints = parseInt(system.args[i + 1]);
    }

    if (system.args[i] === "--hostid" || system.args[i] === "-i") {
        hostId = system.args[i + 1];
    }

    if (system.args[i] === "--hostname" || system.args[i] === "-n") {
        hostName = system.args[i + 1];
    }
}

var username, password;
var numberOfAppPoints;
var hostId, hostName;

if (username === undefined || password === undefined) {
    console.error("ERROR: Missing user / password information.");
    phantom.exit(1);
}

page.onError = function(msg, trace) {
    return;
}

page.onLoadStarted = function() {
    loadInProgress = true;
};

page.onLoadFinished = function() {
    loadInProgress = false;
};

page.onConsoleMessage = function(message) {
    console.log(message);
}


var steps = [

    {
        title: "Loading login page",
        invoker: function() {
            // loading the login page
            return page.open('https://licensing.subscribenet.com/control/ibmr/login', function(status) {
                page.evaluate(function(message) {
                    console.log(message);
                })
            });
        }
    },

    {
        title: "Load connection page",
        invoker: function() {
            page.evaluate(function() {
                var links = document.getElementsByClassName("ibm-external-link tipso_style ibm-widget-processed");
                if (links && links.length > 0) {
                    links[0].click();
                }
            });
        }
    },

    {
        title: "Submit credentials",
        invoker: function() {
            // entering credentials
            page.evaluate(function(username, password) {
                document.getElementById("itraUsername").value = username;
                document.getElementById("itraPassword").value = password;
                document.getElementById("itraLoginForm").submit();
            }, username, password);
        }
    },

    {
        title: "Select IBM AppPoint Suites",
        invoker: function() {
            // selection "IBM AppP Points link"
            page.evaluate(function() {
                var res = document.evaluate('//a[text()="IBM AppPoint Suites"]', document, null, XPathResult.ANY_TYPE, null);
                var link = res.iterateNext();
                if (link === undefined) return 1;

                link.click();
            });
        }
    },

    {
        title: "Select IBM MAXIMO APPLICATION SUITE AppPOINT LIC",
        invoker: function() {
            // selection "IBM MAXIMO APPLICATION SUITE AppPOINT LIC link"
            page.evaluate(function() {
                var res = document.evaluate('//a[text()="IBM MAXIMO APPLICATION SUITE AppPOINT LIC"]', document, null, XPathResult.ANY_TYPE, null);
                var link = res.iterateNext();
                if (link === undefined) return;

                link.click();
            });
        }
    },

    {
        title: "Validate product",
        invoker: function() {
            // click on button itraLicenseRightListFormGenerateButton
            page.evaluate(function() {
                var res = document.getElementById("itraLicenseRightListFormGenerateButton");
                if (res === undefined) return;

                res.click();
            });
        }
    },


    {
        title: "Input generation details",
        invoker: function() {
            // input generation details
            page.evaluate(function(numberOfAppPoints, hostId, hostName) {
                var res = document.getElementById("parameterGroup1_licenseQty");
                if (res === undefined) return;
                res.value = numberOfAppPoints;

                res = document.getElementById("parameterGroup1_svrHostIdType0");
                if (res === undefined) return;
                res.value = "HST_TYP_ETHER";

                res = document.getElementById("parameterGroup1_svrHostIdType0");
                if (res === undefined) return;
                res.value = "HST_TYP_ETHER";

                res = document.getElementById("parameterGroup1_svrHostId0");
                if (res === undefined) return;
                res.value = hostId;

                res = document.getElementById("parameterGroup1_svrHostName0");
                if (res === undefined) return;
                res.value = hostName;

                res = document.getElementById("itraGenerateLicensesSubmitButton");
                if (res === undefined) return;
                res.click();
            }, numberOfAppPoints, hostId, hostName);
        }
    },

    {
        title: " Fetch license file",
        invoker: function() {
            // click on download button
            page.evaluate(function() {
                console.log("----- BEGIN LICENSE -----");
                console.log(document.getElementsByTagName("textarea")[0].value);
                console.log("----- END LICENSE -----");
            });
        }
    }
];


var step = 0;
var loadInProgress = false;
var interval = setInterval(function() {
    if (!loadInProgress) {
        var current = steps[step];
        console.log((step + 1) + "/" + steps.length + ") " + current.title);
        current.invoker();
        step++;

    }
    if (step == steps.length) {
        phantom.exit();
    }
}, 1000);