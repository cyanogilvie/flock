tcl::tm::path add /tm
package require common_sighandler
package require flock
package require rl_json
package require logging
package require parse_args

interp alias {} json {} ::rl_json::json
interp alias {} parse_args {} ::parse_args::parse_args

parse_args $argv {
	-loglevel	{-default notice}
	-debug		{-boolean}
	-type		{-default raven}
}

logging::logger log $loglevel -cmd {puts stderr}
if {$debug} {
	proc ?? script {uplevel 1 $script}
} else {
	proc ?? args {}
}

proc containerinfo {} {
	package require docker
	docker container inspect -id $::env(HOSTNAME)
}

proc ip {} {lindex [regexp -inline {src ([^ ]+)} [exec ip -o route get 8.8.8.8]] 1}

m2::api2 create m2 -uri tcp://m2node

namespace eval ::req {
	namespace export *
	namespace ensemble create -prefixes no

	proc hello noun {
		return "hello, $noun"
	}

	proc longreq {} {
		after 1500 [list [info coroutine]]
		yield
		return finished
	}

	proc shortreq {} {
		after 10 [list [info coroutine]]
		yield
		return finished
	}

	proc with_updates {} {
		after 10 [list [info coroutine]]; yield
		flock_req_log notice "First interim update"
		after 19 [list [info coroutine]]; yield
		flock_req_log warning "Second interim update"
		return finished
	}
}

set servicename		[json get [containerinfo] Config Labels com.docker.compose.service]
flock register instvar f -m2 m2 -type $type -id $servicename -onrequest ::req
$f set_type_data containerid	$::env(HOSTNAME)
$f set_type_data service		$servicename
$f set_type_data ip				[ip]

if {![info exists exit]} {vwait exit}
exit $exit
