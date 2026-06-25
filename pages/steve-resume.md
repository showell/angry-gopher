# Steve Howell

showell285@gmail.com · 202-213-7553
Chambersburg, PA · US-based, willing to relocate

Senior software engineer with recent experience developing alongside the Claude agent in Zig, Go, JavaScript, TypeScript, and Python.

**Languages:** C / C++ / Zig / Odin · Go / Java · Python / Ruby / Perl · JS / TS / CoffeeScript / Elm · SQL / HTML / CSS

## Education

**Duke University** — Durham, NC, Class of 1989
Phi Beta Kappa. BS with a double major (Computer Science / Electrical Engineering) completed in three years.

## Experience

### Personal Projects — 2026

- **January** — Mentored a colleague on contributing to Zulip; co-authored commits for third-party integrations and personalization.
- **February** — Developed the card game Lyn Rummy in TypeScript.
- **March** — Learned Go, Odin, and Zig.
- **April** — Taught an agent (Claude) to play an optimal version of Lyn Rummy.
- **May** — Steered Claude to write a Go-based Chat/Docs system.
- **June** — Had Claude write a 3D safari driving game, and ported the Chat/Docs system to Zig.

### Zulip / Kandra Labs — 2016–2025

*Open-source office chat application*

I contributed to Zulip for about a decade as it grew into one of the premier open-source office chat applications, and I was one of the project's most prolific contributors. Zulip is a large chat system with a wide surface area — messaging, search, notifications, presence, permissions, and administration — built on Python, Django, and PostgreSQL on the backend; jQuery/JavaScript (and eventually TypeScript) on the frontend; and a real-time event system connecting the two. I made over 5,700 atomic commits across the codebase during my tenure. My role, broadly, was to improve the code along four axes: readability, reliability, usability, and performance.

I was comfortable working in a large legacy codebase, and much of my work involved making difficult structural changes to it. I regularly took sprawling, tightly coupled code and extracted the key concepts into cleaner, more modular components — for example, consolidating dozens of ad hoc event-validation checks into a single shared schema, or carving a hard-to-test piece of UI logic out into its own module so the surrounding code could be tested thoroughly. These changes usually had to be made in the face of legacy constraints and other code that depended on the existing behavior, which meant understanding the system deeply before changing anything.

A significant portion of my work targeted performance. On the backend, I optimized Django ORM queries — tuning queries, indexes, and Python-side ORM code to do less work.

I also built Zulip's unit-testing framework on Node.js in 2014, and it is still in use today.

### Software Engineer — Dropbox

*Apr 2014 – Oct 2014 · San Francisco Bay Area*

Zulip was acquired by Dropbox in March 2014. I worked on various projects there, including adding groups support to Dropbox for Business and speeding up their continuous-integration steps. I worked almost exclusively in Python, interacting with proprietary Dropbox code to build web interfaces and manage distributed metadata for customers' uploaded/synced files.

### Software Engineer — Zulip, Inc.

*Apr 2013 – Mar 2014 · Cambridge, MA*

I was one of the original ten developers at the Cambridge-based Zulip startup. The company was founded by four MIT graduates who had successfully exited another startup and saw a niche for topic-based chat. We built out a successful beta program for about thirty organizations on a common tech stack for the time — jQuery on the front end, Django on the back. All team members focused on full-stack features, so I split my time roughly 50/50 between JavaScript and Python.

### Software Engineer — DomainTools LLC

*Feb 2012 – Apr 2013*

When I worked at domaintools.com, the company was still mostly focused on services centered on its extensive in-house database of domain records. I helped maintain their PHP website tools and Python backend systems, and I also wrote significant amounts of C. Some of the daily map/reduce jobs that analyzed vast datasets of domain data were still written in Python; I ported them to C to make the programs 30x faster. That work included a lightweight home-grown JSON parser and an arena-based allocation system to prevent memory leaks.

### Software Developer — AmazonFresh

*Sep 2007 – Jan 2009 · Seattle, WA*

I developed software for the AmazonFresh grocery-delivery service. Our team split time between the Java-based customer-facing website and the Ruby-on-Rails-based warehouse management system (WMS). I mostly focused on the WMS, writing browser-based software for the warehouse scanner devices so associates could receive, stow, pick, pack, and load groceries. We used a MySQL database to track inventory throughout its life cycle — from the receiving truck to the delivery truck. I also worked on the reporting systems that let managers track inventory, associate productivity, and delivery status.

Because we operated in a single exploratory market (Seattle), we were not writing software at tremendous scale, and we used rudimentary (but effective) Rails concepts to build the entire warehouse-facing system. The challenge, instead, was that we iterated very quickly on new features and new *processes* in the warehouse. The whole software team worked closely with product and warehouse managers to evaluate, improve, and automate processes for picking, stowing, packing, and more. Amazon already had tremendous experience delivering books and other consumer products, but it had never dealt with the challenges of groceries — perishables, separate picking zones for frozen/cold items, and delivery trucks owned and operated by Amazon.

During my tenure we optimized processes enough to achieve marginal profits against operating costs, though not against the full cost structure of product teams, software developers, and the like. The eventual outcome of the AmazonFresh experiment was that leadership bought Whole Foods (I may be oversimplifying). More importantly, Amazon learned a great deal about last-mile delivery in a very tricky market, and the software my teammates and I developed was integral to that exploration.

### Software Developer — Merchant Link

*Apr 2004 – Sep 2007*

I developed credit-card gateway applications in Python, along with supporting tools such as accounting and performance monitoring (some web-based). I also performed production-support activities such as troubleshooting and deploying major software releases.

### Software Developer — NXT

*1997 – Jul 1999*

This company later became Merchant Link / Chase Paymentech through acquisitions (where I worked again in 2004–2007). During my original tenure at NXT, I primarily wrote asynchronous credit-card gateway software in straight C on Sun/Solaris. Our small team of five wrote to multiple credit-card formats and protocols, processing nearly a million transactions per day in the 1990s, mostly through two large Unix boxes.

I was also the primary architect of some of our monitoring and error-tracking systems, written in C/C++. We had a small suite of automated tests, but we honestly relied on extensive code review to ensure the high quality and reliability of the software. The format translations were mostly mechanical, but the protocol translations required a deep understanding of the async nature of legacy dial-up credit-card protocols and the careful construction of state machines in C to react to unexpected events and line noise.

### Software Consultant — Watson Wyatt Worldwide

*Jun 1992 – Nov 1996*

Developed applications for cafeteria-style corporate benefits. C/C++, SQL Server.

### Software Developer — Oracle

*Sep 1989 – Jun 1991*

Helped automate QA for Oracle mainframe products with Rexx. Installed new database releases and reviewed documentation.

### Internships

- **Summer 1989** — Computer Sciences Corporation
- **Summer 1988** — Noise Cancellation Technologies
- **Summer 1987** — Computer Sciences Corporation
- **Summer 1986** — Computer Sciences Corporation
