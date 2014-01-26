<?php
/**
 * PHP API client library.  Simple wrapper around curl functions
 *
 * If you are planning on calling the CanIt API from PHP, you should
 * use this library.  It's MUCH easier than writing your own CURL calls.
 *
 * SYNOPSIS:
 *
 * require_once("canit-api-client.php");
 *
 *
 * CREATION: Create a CanItAPIClient object:
 *
 * $c = new CanItAPIClient("http://server.example.com/canit/api/2.0");
 *
 * LOGIN:
 *
 * $success = $c->login('username', 'password');
 * if ($success) {
 *     print "Successful login.\n";
 * } else {
 *     print "Login failed: " . $c->get_last_error() . "\n";
 * }
 *
 * REQUESTS:
 *
 * Do a GET request.  Example: Get a list of users.  Return value
 * is an array of arrays; each subarray is an associative array of users
 *
 * $users = $c->do_get('realm/@@/users');
 * if (!$c->succeeded()) {
 *     print "GET request failed: " . $c->get_last_error() . "\n";
 * } else {
 *     print "Got users:\n";
 *     print_r($users);
 * }
 *
 * Do a PUT request.  Example: Create a realm.
 *
 * $c->do_put('realm/foobar', array('description' => 'The new realm'));
 * if (!$c->succeeded()) {
 *     print "PUT request failed: " . $c->get_last_error() . "\n";
 * } else {
 *     print "Created realm foobar.\n";
 * }
 *
 * Do a POST request.  Example: Update a realm.
 *
 * $c->do_post('realm/foobar', array('description' => 'Different description'));
 * if (!$c->succeeded()) {
 *     print "POST request failed: " . $c->get_last_error() . "\n";
 * } else {
 *     print "Updated realm foobar.\n";
 * }
 *
 * Do a DELETE request.  Example: Delete a stream
 *
 * $c->do_delete('realm/@@/stream/wookie');
 * if (!$c->succeeded()) {
 *     print "DELETE request failed: " . $c->get_last_error() . "\n";
 * } else {
 *     print "Deleted stream wookie.\n";
 * }
 *
 * LOGOUT:
 *
 * $c->logout();
 */


class CanItAPIClient {
    /**
     * CanItAPIClient Constructor
     *
     * @param string $url The base URL of the API server.  Eg: http://127.0.0.1/canit/api/2.0
     */
    function CanItAPIClient ($url) {
	# Remove trailing slashes from $url
	$url = rtrim($url, '/');

	$url = $url . '/json/';

	$this->url = $url;
	$this->is_error = 0;
	$this->last_error = '';
	$this->curl_response = '';
	$this->curl_content = '';
	$this->curl_headers = '';
	$this->curl_content_type = '';
	$this->cookie = '';
    }

    /**
     * Get the last API-related error message
     * @return string
     */
    function get_last_error () {
	return $this->last_error;
    }

    /**
     * Returns true if the last API call failed,
     * false if it succeeded
     * DEPRECATED: You should use the succeeded() function instead
     */
    function is_error() {
	return $this->is_error;
    }

    /**
     * Returns true if the last API call succeeded,
     * false if it failed
     */
    function succeeded() {
	return ! $this->is_error;
    }

    /**
     * Log in to the API
     * @param string $username API username
     * @param string $password API password
     * @return boolean True on successful login; false otherwise
     */
    function login($username, $password) {
	$this->do_post('login', array('user' => $username,
				      'password' => $password));
	if ($this->is_error) {
	    return false;
	}

	# Set our cookie
	foreach ($this->curl_headers as $header) {
	    if (strpos($header, ':') !== FALSE) {
		list($name, $val) = explode(':', $header, 2);
	    } else {
		$name = $header;
		$val = '';
	    }
	    $name = strtolower(trim($name));
	    $val = trim($val);
	    if ($name == 'set-cookie') {
		if ($this->cookie != '') {
		    $this->cookie .= '; ';
		}
		$this->cookie .= $val;
	    }
	}
	return true;
    }

    /**
     * Log out of the API
     */
    function logout() {
	$this->do_get("logout");
	$this->cookie = '';
    }

    /**
     * Do a GET request
     * @param string $rel_url The relative URL.  That is everything
     *                        AFTER the /canit/api/2.0/ part of the full
     *                        URL.
     * @param array $params   Search array converted to ?key1=val1&key2=val2...
     * @return NULL on failure, a PHP data structure on success.
     */
    function do_get ($rel_url, $params = null) {
	# If $rel_url begins with a slash, remove it
	$rel_url = ltrim($rel_url, '/');

	$full_url = $this->url . $rel_url;
	if (is_array($params)) {
	    $first_time = 1;
	    foreach ($params as $key => $val) {
		if ($first_time) {
		    $full_url .= '?';
		    $first_time = 0;
		} else {
		    $full_url .= '&';
		}
		$full_url .= urlencode($key) . '=' . urlencode($val);
	    }
	}
	$ch = curl_init();
	$this->curl_call($full_url, $ch);
	curl_close($ch);
	return $this->deserialize_curl_data();
    }

    /**
     * Do a PUT request
     * @param string $rel_url The relative URL.  That is everything
     *                        AFTER the /canit/api/2.0/ part of the full
     *                        URL.
     * @param array $put_data An associative array of key/value pairs.
     * @return void Nothing useful; check $this->is_error() to test success
     */
    function do_put ($rel_url, $put_data) {
	# If $rel_url begins with a slash, remove it
	$rel_url = ltrim($rel_url, '/');

	$full_url = $this->url . $rel_url;
	$ch = curl_init();
	curl_setopt($ch, CURLOPT_CUSTOMREQUEST, 'PUT');
	$encoded = json_encode($put_data);
	curl_setopt($ch, CURLOPT_HTTPHEADER, array('Content-Length: ' . strlen($encoded)));
	curl_setopt($ch, CURLOPT_POSTFIELDS, $encoded);
	$this->curl_call($full_url, $ch);
	curl_close($ch);
	return $this->deserialize_curl_data();
    }

    /**
     * Do a DELETE request
     * @param string $rel_url The relative URL.  That is everything
     *                        AFTER the /canit/api/2.0/ part of the full
     *                        URL.
     * @return void Nothing useful; check $this->is_error() to test success
     */
    function do_delete ($rel_url) {
	# If $rel_url begins with a slash, remove it
	$rel_url = ltrim($rel_url, '/');

	$full_url = $this->url . $rel_url;
	$ch = curl_init();
	curl_setopt($ch, CURLOPT_CUSTOMREQUEST, 'DELETE');
	$this->curl_call($full_url, $ch);
	curl_close($ch);
	return NULL;
    }

    /**
     * Do a POST request
     * @param string $rel_url The relative URL.  That is everything
     *                        AFTER the /canit/api/2.0/ part of the full
     *                        URL.
     * @param array $put_data An associative array of key/value pairs.
     * @return void Nothing useful; check $this->is_error() to test success
     */
    function do_post ($rel_url, $post_data) {
	# If $rel_url begins with a slash, remove it
	$rel_url = ltrim($rel_url, '/');

	$full_url = $this->url . $rel_url;
	$ch = curl_init();
	curl_setopt($ch, CURLOPT_POST, true);
	curl_setopt($ch, CURLOPT_POSTFIELDS, $post_data);
	$this->curl_call($full_url, $ch);
	curl_close($ch);
	return $this->deserialize_curl_data();
    }

    /** ==== END OF PUBLIC FUNCTIONS.  REMAINING FUNCTIONS ARE PRIVATE;
     ** ==== DO NOT CALL THEM DIRECTLY
     **/

    function curl_call($url, $ch) {
	curl_setopt($ch, CURLOPT_URL, $url);
	curl_setopt($ch, CURLOPT_FOLLOWLOCATION, true);
	curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
	curl_setopt($ch, CURLOPT_CONNECTTIMEOUT, 10);
	curl_setopt($ch, CURLOPT_MAXREDIRS, 5);
	curl_setopt($ch, CURLOPT_TIMEOUT, 30);
	curl_setopt($ch, CURLOPT_HEADER, true);
	curl_setopt($ch, CURLOPT_FORBID_REUSE, true);
	if ($this->cookie != '') {
	    curl_setopt($ch, CURLOPT_COOKIE, $this->cookie);
	}
	curl_setopt($ch, CURLOPT_HTTPHEADER, array('Expect:', 'Accept: application/json'));
	$result = curl_exec($ch);
	if ($result === false) {
	    $this->is_error = 1;
	    $this->last_error = curl_error($ch);
	} else {
	    $arr = explode("\r\n\r\n", $result, 3);
	    $this->curl_headers = explode("\r\n", $arr[0]);
	    $this->curl_content = $arr[1];
	    $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
	    if ($code >= 200 && $code <= 299) {
		$this->curl_content_type = curl_getinfo($ch, CURLINFO_CONTENT_TYPE);
		$this->is_error = 0;
		$this->last_error = '';
	    } elseif ($code >= 400 && $code <= 599) {
		$this->is_error = 1;
		$this->set_error_from_result($this->curl_content);
	    } else {
		$this->is_error = 1;
		$this->last_error = "Unknown HTTP response $code";
	    }
	}
    }

    function set_error_from_result ($result) {
	# Special case: Login failures always come back in YAML
	# in old/buggy versions of API... sigh.
	if (substr($result, 0, 11) == "---\nerror: ") {
	    $this->last_error = substr($result, 11);
	    return;
	}
	$data = json_decode($result, true);
	if (!is_array($data)) {
	    $this->last_error = "Unknown error: $data";
	} elseif (array_key_exists('error', $data)) {
	    $this->last_error = $data['error'];
	} else {
	    $this->last_error = 'Unknown error';
	}
    }

    function deserialize_curl_data () {
	if ($this->is_error) return NULL;
	if ($this->curl_content_type == 'message/rfc822') {
	    return array('message' => $this->curl_content);
	}

	return json_decode($this->curl_content, true);
    }

}

?>
