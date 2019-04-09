# What changes we can't accept

We wish we could accept all changes, especially changes that make the organization or readability of the project better. Unfortunately we can't, due to technical limitations 😢.

## What is up with this weird module map, or strange import statement 🤷‍♂️?

We host our source code inside Google and treat that as the “source of truth”. The internal build toolchain and dependency manager are not cocoapods. In order to be able to work with both internal and external tooling, we’ve had to make some concessions with how the project is set up. There are a number of considerations you must make if you’re thinking about changing things that look non-standard. 

### Module maps and import statements

We use custom module maps that link directly to various dependencies like [SSOAuth](https://github.com/google/science-journal-ios/blob/master/ModuleMaps/SSOAuth.modulemaps/module.modulemap). We can’t modify these as our internal dependency management tool has some requirements that necessitate the current import format. You can see that come into play where imports are prefixed with things like “[googlemac_iPhone](https://github.com/google/science-journal-ios/blob/master/ScienceJournal/Accounts/AccountsManager.swift#L19)”. Sadly, we must leave these in.

### Updating Swift

We want to be running the latest Swift 🏃‍♀️ as much as anybody. At this time we can’t accept Swift version update PRs. Our internal source of truth must be updated first. Because the internal source of truth has more code than the open source project, we’ll have to do the migration, and test it internally to make sure all of our tooling works- inside and outside of Google.

### Podfile updates

Adding new pods isn’t out of the question, but please be mindful as we only support Apache 2.0, and MIT licensed software.

Updating the pods that are used is a different story too, that is, it's unlikely we can accept any pod updates. We have more internal requirements that must be satisfied so we limit podfile updates to new features, bug fixes, and security updates that impact us. 
