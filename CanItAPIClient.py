import pycurl
import json
import urllib
import StringIO

# Python API client library.  Simple wrapper around curl functions
#
#
# SYNOPSIS:
#
# import CanItAPIClient
#
#
# CREATION: Create a CanItAPIClient object:
#
# c = CanItAPIClient.CanItAPIClient("http://server.example.com/canit/api/2.0")
#
# LOGIN:
#
# success = c.login('username', 'password')
# if success:
#     print "Successful login"
# else:
#     print "Login failed: " + c.get_last_error()
#
# REQUESTS:
#
# Do a GET request.  Example: Get a list of users.  Return value
# is an array of dictionaries.
#
# users = c.do_get('realm/@@/users')
# if c.succeeded():
#     print "Got users"
#     print users
# else:
#     print "GET request failed: " + c.get_last_error()
#
# Do a PUT request.  Example: Create a realm.
#
# c.do_put('realm/foobar', {'description' : 'The new realm'})
# if c.succeeded():
#     print "Created realm foobar."
# else:
#     print "PUT request failed: " + c.get_last_error()
#
# Do a POST request.  Example: Update a realm.
#
# c.do_post('realm/foobar', {'description' : 'Different description'})
# if c.succeeded():
#     print "Updated realm foobar."
# else:
#     print "POST request failed: " + c.get_last_error()
#
# Do a DELETE request.  Example: Delete a stream
#
# c.do_delete('realm/@@/stream/wookie')
# if c.succeeded():
#     print "Deleted stream wookie.\n"
# else:
#     print "DELETE request failed: "  + c.get_last_error()
#
# LOGOUT:
#
# c.logout()

class CanItAPIClient:
    """A simple client-side library for accessing the CanIt API"""
    def __init__(self, url):
        # Remove trailing slashes from url
        url = url.rstrip('/')
        url = url + '/json/'
        self.url = url
        self.is_error = 0
        self.last_error = ''
        self.curl_response = ''
        self.curl_content = ''
        self.curl_headers = ''
        self.cookie = ''
        pycurl.global_init(pycurl.GLOBAL_ALL)

    def get_last_error(self):
        """Returns the last CURL error if most recent call failed."""
        return self.last_error

    def succeeded(self):
        """Returns true if most recent API call succeeded; false otherwise."""
        return not self.is_error

    def login(self, username, password):
        """Log in to the API."""
        self.do_post('login', [('user', username), ('password', password)])
        if self.is_error:
            return False
        for header in self.curl_headers:
            lst = header.split(':', 2)
            if len(lst) < 2:
                continue
            name = lst[0].lower()
            val = lst[1].strip()
            if name == 'set-cookie':
                if self.cookie != '':
                    self.cookie = self.cookie + '; '
                self.cookie = self.cookie + val
        return True

    def logout(self):
        """Log out of the API and release cookie."""
        self.do_get('logout')
        self.cookie = ''
        return True

    def do_get(self, rel_url):
        """Do a GET request against the API server."""
	# If rel_url begins with a slash, remove it
        rel_url = rel_url.lstrip('/')
        full_url = self.url + rel_url
        c = pycurl.Curl()
        self.curl_call(full_url, c)
        c.close()
        return self.deserialize_curl_data()

    def do_put(self, rel_url, put_data):
        """Do a PUT request against the API server.  put_data should
        be a dictionary."""
	# If rel_url begins with a slash, remove it
        rel_url = rel_url.lstrip('/')
        full_url = self.url + rel_url
        c = pycurl.Curl()
        c.setopt(pycurl.CUSTOMREQUEST, 'PUT')

        # We don't know which version of the JSON API
        # we have... sigh...
        try:
            encoded = json.dumps(put_data)
        except AttributeError:
            encoded = json.write(put_data)

        c.setopt(pycurl.POSTFIELDS, encoded)
        c.setopt(pycurl.HTTPHEADER, ['Content-Type: application/json',
                                     'Content-Length: ' + str(len(encoded))])
        self.curl_call(full_url, c)
        c.close()
        return self.deserialize_curl_data()


    def do_delete(self, rel_url):
        """Do a DELETE request against the API server."""
	# If rel_url begins with a slash, remove it
        rel_url = rel_url.lstrip('/')
        full_url = self.url + rel_url
        c = pycurl.Curl()
        c.setopt(pycurl.CUSTOMREQUEST, 'DELETE')
        self.curl_call(full_url, c)
        c.close()
        return None

    def do_post(self, rel_url, post_data):
        """Do a POST request against the API server.  post_data should
        be a dictionary."""
	# If rel_url begins with a slash, remove it
        rel_url = rel_url.lstrip('/')
        full_url = self.url + rel_url
        c = pycurl.Curl()
        c.setopt(pycurl.POST, True)
        c.setopt(pycurl.POSTFIELDS, urllib.urlencode(post_data))
        self.curl_call(full_url, c)
        c.close()
        return self.deserialize_curl_data()

#==== END OF PUBLIC FUNCTIONS.  REMAINING FUNCTIONS ARE PRIVATE;
#==== DO NOT CALL THEM DIRECTLY

    def curl_call(self, url, c):
        c.setopt(pycurl.URL, url);
        c.setopt(pycurl.FOLLOWLOCATION, 1);
        c.setopt(pycurl.CONNECTTIMEOUT, 10);
        c.setopt(pycurl.MAXREDIRS, 5);
        c.setopt(pycurl.TIMEOUT, 30);
        c.setopt(pycurl.HEADER, 1);
        c.setopt(pycurl.FORBID_REUSE, 1)

	if (self.cookie != ''):
            c.setopt(pycurl.COOKIE, self.cookie)

	c.setopt(pycurl.HTTPHEADER, ['Expect:', 'Accept: application/json'])
        ans = StringIO.StringIO()
        c.setopt(pycurl.WRITEFUNCTION, ans.write)
        try:
            c.perform()
        except:
            self.is_error = 1
            self.last_error = c.errstr()
            return None

        lst = ans.getvalue().split("\r\n\r\n", 3)
        self.curl_headers = lst[0].split("\r\n")
        self.curl_content = lst[1]

        code = c.getinfo(pycurl.HTTP_CODE)
        if code >= 200 and code <= 299:
            self.is_error = 0
            self.last_error = ''
        elif code >= 400 and code <= 599:
            self.is_error = 1
            self.set_error_from_result(self.curl_content, code)
        else:
            self.is_error = 1
            self.last_error = 'Unknown HTTP response ' + str(code)


    def set_error_from_result(self, result, code):
        code = str(code)
        if (result == ''):
            self.last_error = 'Unknown error: HTTP Code ' + code
            return
        try:
            data = json.loads(result)
        except AttributeError:
            try:
                data = json.read(result)
            except:
                self.last_error = 'Unknown error: HTTP Code ' + code
                return
        except:
            self.last_error = 'Unknown error: HTTP Code ' + code
            return

        if not isinstance(data, dict):
            self.last_error = 'Unknown error: HTTP Code ' + code
            return

        if data.has_key('error'):
            self.last_error = data['error']
            return

        self.last_error = 'Unknown error: HTTP Code ' + code

    def deserialize_curl_data(self):
        if (self.curl_content == ''):
            return None

        if (self.is_error):
            return None

        try:
            ans = json.loads(self.curl_content)
        except AttributeError:
            ans = json.read(self.curl_content)

        return ans
