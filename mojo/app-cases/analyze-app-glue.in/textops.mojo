# Glue for the unit `textops`, filled in: `upper` answers in Mojo.

from textops import port


def upper(args: List[String]) raises -> Int:
    var words = String()
    for i in range(1, len(args)):
        if i > 1:
            words += " "
        words += args[i]
    print(port.upper(words))
    return 0
