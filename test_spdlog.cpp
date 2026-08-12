#include <spdlog/spdlog.h>
#include <iostream>
int main() {
    try {
        const char* p = nullptr;
        spdlog::info("{}", p);
        std::cout << "survived" << std::endl;
    } catch (const std::exception& e) {
        std::cout << "exception: " << e.what() << std::endl;
    }
    return 0;
}
