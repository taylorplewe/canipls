#ifndef _CANIUSE_HPP
#define _CANIUSE_HPP


#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace Caniuse {
    struct VersionMapping {
        float version;
        float percentage;
        float total_percentage_from_here;
    };
    typedef std::vector<VersionMapping>                 VersionMap;
    typedef std::unordered_map<std::string, VersionMap> BrowserSupportMap;
    typedef std::allocator<VersionMapping>              VersionMapAllocator;

    void parse_caniuse_support_html_and_fill_support_map(BrowserSupportMap*, VersionMapAllocator&);
    void print_support_map(BrowserSupportMap*);
}


#endif
