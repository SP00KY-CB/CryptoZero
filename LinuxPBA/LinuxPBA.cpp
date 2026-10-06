/* C:B**************************************************************************
This software is Copyright 2014-2017 Bright Plaza Inc. <drivetrust@drivetrust.com>

    This file is part of sedutil.

    sedutil is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    sedutil is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with sedutil.  If not, see <http://www.gnu.org/licenses/>.

* C:E********************************************************************** */


#include <unistd.h>
#include <sys/reboot.h>
#include <iostream>
#include <cstring>
#include "log.h"
#include "GetPassPhrase.h"
#include "UnlockSEDs.h"

using namespace std;

/* Default to output that includes timestamps and goes to stderr*/
sedutiloutput outputFormat = sedutilNormal;

int main(int argc, char** argv) {
    
    CLog::Level() = CLog::FromInt(0);
    /* Non-interactive mode used by cz-unlock: the (already derived) key is
     * read from stdin, and the exit status reports whether every locked
     * drive was unlocked. The caller is responsible for rebooting. */
    if (argc > 1 && !strcmp(argv[1], "--key-stdin")) {
        string k;
        if (!getline(cin, k) || k.empty())
            return 2;
        uint8_t rc = UnlockSEDs((char *)k.c_str());
        k.assign(k.size(), '\0');
        return rc ? 1 : 0;
    }
    LOG(D4) << "Legacy PBA start" << endl;
//    system ("tput clear");
    printf("Boot Authorization \n");
    string p = GetPassPhrase("Password: ");
    UnlockSEDs((char *)p.c_str());
    if (strcmp(p.c_str(), "debug")) {
        printf("\n Access granted. Starting the system... \n");
        sync();
        reboot(RB_AUTOBOOT);
    }
    return 0;
}

