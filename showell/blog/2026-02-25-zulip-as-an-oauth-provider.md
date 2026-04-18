## Zulip as an OAuth Provider

*February 25, 2026*

I am looking at [#16529](https://github.com/zulip/zulip/pull/16529/changes) today,
and I am going through it to see what we need to do to dust off
that PR.

#### Overall strategy

Tim is on board with resurrecting this PR if we can just work
through the merge conflicts.

The main hindrance here is that we have to re-do all the
provision steps. I honestly think it will be easier to just
start over.  We want to re-do the provision-related steps,
and then we can just crib off the PR for the other stuff.

The PR has four separate commits, but we don't need to
presever the individual commits.

I'm not sure the commits were ever atomic, and
most of this code is additive and interdependent anyway.

#### Use case: writing a proxy server

In order to keep things a bit concrete, I am going to talk
about a specific use case. It's the use case that Rohitt and
I had when we worked on the OAuth PR.

We had a Proxy Server that Zulip users could connect to
with their custom clients.

Our Proxy let the clients use websockets instead of doing
long-polling, and it provided some other services.

Let's move to present tense:

The Client connects to the Proxy, but of course the Client
does not want to hand over its API key to the Proxy. Instead,
the Proxy starts an oauth flow with the Client.

The Client tells Zulip (offline, so to speak) that it
trusts the Proxy to hold an OAuth token.

The Client then gives the Proxy its OAuth token (and of
course that's out of the scope of this PR).

Once the Proxy gets its hands on the OAuth token, the Proxy
starts talking to Zulip using the OAuth token (instead of the
Client's API key).

##### Order of describing things

Note that I am trying to talk about the PR in the same order
as the diffs show changes, so it's not gonna be completely
as sequential as the actual "real world" way to think about this.

#### django-oauth-toolkit library

We use `django-oauth-toolkit` as our oauth library.

Some of the PR is merely pulling in the library as a
dependency.

We will essentially want to repeat that process.
Back in 2020 that process led to these changes at
the top of the PR diff:

* requirements/common.in
* requirements/dev.txt
* requirements/prod.txt

It's not **totally** clear how long we will actually
need the library.  Mostly what it gives us is admin
screens that we eventually need to re-write anyway.

#### Where do we invoke the library?

Apart from all the admin screens (described later),
we hardly ever call into the library.

This is where the rubber hits the road:

``` py

    (ok, req) = get_oauthlib_core().verify_request(request, [])
    if not ok:
        raise JsonableError(_("oauth failed"))
```

(We will probably want to extract a one-line function
to encapsulate that, if only to simplify mocking in
Python tests.  And we may eventually replace it with
our own version. Under the hood, the library is just
managing a collection of tokens, probably backed by
the database.)

You can see the code in context further down.  Presumably the
library just knows which request headers to look at. It
finds the token sent by Proxy (in our example) and just
makes sure the token hasn't expired or been removed.

We can study the implementation of `verify_request(...)`
within the actual source of the toolkit library to
see what it does under the hood.

#### Missing details in the PR

I'm 85% sure that the library needs to set up
a few Django models to work. It's not clear how
we ran migrations back in 2020. I vaguely remember
that we just ran them manually.

#### Admin screens

We will resurrect `zerver/lib/oauth2.py` basically verbatim:

```
import oauth2_provider.views as oauth2_views
from django.urls import path

oauth2_endpoint_views = [
    # OAuth2 Application Management endpoints
    path('applications/', oauth2_views.ApplicationList.as_view(), name="list"),
    path('applications/register/', oauth2_views.ApplicationRegistration.as_view(), name="register"),
    path('applications/<pk>/', oauth2_views.ApplicationDetail.as_view(), name="detail"),
    path('applications/<pk>/delete/', oauth2_views.ApplicationDelete.as_view(), name="delete"),
    path('applications/<pk>/update/', oauth2_views.ApplicationUpdate.as_view(), name="update"),

    # tokens
    path('authorize/', oauth2_views.AuthorizationView.as_view(), name="authorize"),
    path('token/', oauth2_views.TokenView.as_view(), name="token"),
    path('revoke-token/', oauth2_views.RevokeTokenView.as_view(), name="revoke-token"),
]
```

I forget how these links work exactly, but they basically all
go through the third party library.

They are kind of like the equivalent of Django admin screens,
because they essentially **are** Django admin screens. (I don't
remember if they are literally built like that or not.)

We eventually need to replace them with Zulip versions that are
properly skinned and integrated into Zulip.

#### HTTP_BEARER headers

I haven't talked about how the user actually **gets** authenticated
to Zulip yet, but let's skip ahead.

Once the Proxy (in our example use case) has an oauth token
for its Client, it talks to Zulip using the oauth token instead
of the API key.  It sends it as an HTTP header with the key
of `HTTP_BEARER`.  So this leads to a one-line diff in
`zerver/lib/rest.py`:

``` diff
         # most clients (mobile, bots, etc) use HTTP Basic Auth and REST calls, where instead of
         # username:password, we use email:apiKey
-        elif request.META.get('HTTP_AUTHORIZATION', None):
+        elif request.META.get('HTTP_AUTHORIZATION') or request.META.get("HTTP_BEARER"):
```

And then most of the things that we have to do to let
Zulip accept those inbound requests from the Proxy happen
in `zerver/decorator.py`.  We can look at the diff in the
PR for all the details, but here is 50% of the problem solved:
we just need to validate the oauth key using the library's
`verify_request(...)` helper:

``` py
def validate_oauth_key(request: HttpRequest) -> UserProfile:
    access_token = request.META.get("HTTP_BEARER")
    request.META["Authorization"] = f"bearer {access_token}"

    (ok, req) = get_oauthlib_core().verify_request(request, [])
    if not ok:
        raise JsonableError(_("oauth failed"))

    # convert from AnonymousUser
    user_profile = UserProfile.objects.get(id=req.user.id)
    request.user = user_profile

    validate_account_and_subdomain(request, user_profile)

    # Using oauth for webhooks might make sense some day, but we punt for now.
    if user_profile.is_incoming_webhook:
        raise JsonableError(_("This API is not available to incoming webhook bots."))

    client_name = "beta oauth"
    process_client(request, user_profile, client_name=client_name)
    return user_profile
```

The rest of the diff is a bit hard to read due to indentation, but
we are essentially just adding another condition inside of
`authenticated_rest_api_view`:

``` py
            elif request.META.get("HTTP_BEARER"):
                try:
                    profile = validate_oauth_key(request)
                except JsonableError as e:
                    return json_unauthorized(e.msg)
            else:
                # our caller should defend against missing headers, not us
                raise AssertionError("expected some kind of header")
```

In the comment where it says "our caller should defend", that
is up in `zerver/lib/rest.py` (see the one-line diff up above).

#### Django templates for admin screens

The diff inside of `zproject/computed_settings.py` sets
up Django templates for the oauth toolkit to use.
If we write our own admin screens, then these will go away.
But for now just pull them in verbatim.

#### Exposing urls

The change to `zproject/urls.py` does nothing more than import
`oauth2_endpoint_views` and then add those to `urls`:

``` py
# Experimental oauth provider support.
urls += [
    path('o/', include((oauth2_endpoint_views, 'oauth2_provider'),)),
]
```

### version.py

The last diff is bumping `PROVISION_VERSION`, and of course
this will need to change (and certainly is part of why the
PR has merge conflicts).

### Action items

The next steps are for Apoorva to read this. Depending on
the questions that come up, we will want to dig into the
zulip-proxy code just to understand better what the Client
and Proxy are doing.

And we will want to look at the toolkit's code.

Finally, we want to write a few simple Python tests for
the `decorator.py` changes.
