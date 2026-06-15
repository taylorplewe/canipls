#include <cstdio>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <string_view>
#include <unordered_map>

#include "caniuse.hpp"


#define CIU_USAGE_TABLE_PATH "./ciu-usage-table.html"

namespace CiuSupportTableHtml {
    const std::string BROWSER_HEADING_CLASSNAME    = "browser--";
    const std::string VERSION_NUM_TAG              = "b";
    const std::string VERSION_NUM_CLASSNAME        = "stat-cell__label";
    const std::string VERSION_PERCENTAGE_TAG       = "span";
    const std::string VERSION_PERCENTAGE_CLASSNAME = "stat-cell__percentage";

    // e.g. '<h4 class="browser-heading browser--'
    const std::string BROWSER_HEADING_SEARCH_STRING_BEGIN = BROWSER_HEADING_CLASSNAME;
    const std::string BROWSER_HEADING_SEARCH_STRING_END   = "\"";

    // e.g. '<b class="stat-cell__label">'{version num}':'
    const std::string VERSION_NUM_SEARCH_STRING_BEGIN = "<" + VERSION_NUM_TAG + " class=\"" + VERSION_NUM_CLASSNAME + "\">";
    const std::string VERSION_NUM_SEARCH_STRING_END   = ":";

    // e.g. '<span class="stat-cell__percentage">'{version percentage}'<'
    const std::string VERSION_PERCENTAGE_SEARCH_STRING_BEGIN = "<" + VERSION_PERCENTAGE_TAG + " class=\"" + VERSION_PERCENTAGE_CLASSNAME + "\">";
    const std::string VERSION_PERCENTAGE_SEARCH_STRING_END   = "%";

    std::unordered_map<std::string_view, std::string> ciu_to_bcd_browser_id_mapping = {
        {"chrome", "chrome"},
        {"and_chr", "chrome_android"},
        {"edge", "edge"},
        {"firefox", "firefox"},
        {"and_ff", "firefox_android"},
        {"ie", "ie"},
        {"opera", "opera"},
        {"op_mob", "opera_android"},
        {"safari", "safari"},
        {"ios_saf", "safari_ios"},
        {"samsung", "samsunginternet_android"},
        {"android", "webview_android"},
    };
}

namespace Caniuse {
    void parse_caniuse_support_html_and_fill_support_map(BrowserSupportMap* support_map, VersionMapAllocator& version_map_allocator) {
        // read contents of caniuse browser support table HTML into string
        std::ifstream in;
        in.open(CIU_USAGE_TABLE_PATH, std::ifstream::in);
        std::stringstream sstr;
        sstr << in.rdbuf();
        std::string html = sstr.str();

        std::string_view html_remaining = html;

        size_t
            pos_browser_id,
            pos_version_num,
            pos_version_percentage,
            len_browser_id,
            len_version_num,
            len_version_percentage
        = std::string_view::npos;

        while ((pos_browser_id = html_remaining.find(CiuSupportTableHtml::BROWSER_HEADING_SEARCH_STRING_BEGIN)) != std::string_view::npos) {
            html_remaining.remove_prefix(pos_browser_id + CiuSupportTableHtml::BROWSER_HEADING_SEARCH_STRING_BEGIN.size());
            len_browser_id = html_remaining.find("\"");
            std::string_view browser_id_ciu = html_remaining.substr(0, len_browser_id);
            if (!CiuSupportTableHtml::ciu_to_bcd_browser_id_mapping.contains(browser_id_ciu)) continue;
            std::string browser_id = CiuSupportTableHtml::ciu_to_bcd_browser_id_mapping.at(browser_id_ciu);

            // std::cout << browser_id << std::endl;

            VersionMap version_map = VersionMap(version_map_allocator);

            size_t next_browser_id = html_remaining.find(CiuSupportTableHtml::BROWSER_HEADING_SEARCH_STRING_BEGIN);
            std::string_view browser_html_section = html_remaining.substr(0, next_browser_id);

            while ((pos_version_num = browser_html_section.find(CiuSupportTableHtml::VERSION_NUM_SEARCH_STRING_BEGIN)) != std::string_view::npos) {
                browser_html_section.remove_prefix(pos_version_num + CiuSupportTableHtml::VERSION_NUM_SEARCH_STRING_BEGIN.size());
                len_version_num = browser_html_section.find(CiuSupportTableHtml::VERSION_NUM_SEARCH_STRING_END);
                std::string_view version_num_str = browser_html_section.substr(0, len_version_num);
                float version_num = 9999.0;
                if (version_num_str != "TP" && version_num_str != "all") {
                    version_num = std::stof(version_num_str.data());
                }

                pos_version_percentage = browser_html_section.find(CiuSupportTableHtml::VERSION_PERCENTAGE_SEARCH_STRING_BEGIN);
                browser_html_section.remove_prefix(pos_version_percentage + CiuSupportTableHtml::VERSION_PERCENTAGE_SEARCH_STRING_BEGIN.size());
                len_version_percentage = browser_html_section.find(CiuSupportTableHtml::VERSION_PERCENTAGE_SEARCH_STRING_END);
                std::string_view version_percentage_str = browser_html_section.substr(0, len_version_percentage);
                float version_percentage = std::stof(version_percentage_str.data());

                version_map.push_back({
                    .version = version_num,
                    .percentage = version_percentage,
                    .total_percentage_from_here = 0.0f,
                });

                // memoize total support percentages going downward, for each version
                float total_percentage = 0.0;
                for (int i = version_map.size() - 1; i >= 0; i--) {
                    total_percentage += version_map[i].percentage;
                    version_map[i].total_percentage_from_here = total_percentage;
                }

                // version_map.insert({version_num, version_percentage});

                // std::cout << " " << version_num << ": " << version_percentage << "%" << std::endl;
            }

            support_map->insert({browser_id, version_map});
        }

        in.close();
    }

    void print_support_map(BrowserSupportMap* support_map) {
        // print support map
        for (const std::pair<std::string_view, VersionMap>& browser_entry : *support_map) {
            auto browser_id = browser_entry.first;
            auto version_map = browser_entry.second;

            std::cout << browser_id << std::endl;
            for (const auto mapping : version_map) {
                printf(" %8.2f: %6.2f%% | %6.2f%%\n", mapping.version, mapping.percentage, mapping.total_percentage_from_here);
            }
        }
    }
}
